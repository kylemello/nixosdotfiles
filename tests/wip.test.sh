#!/usr/bin/env bash
# Test suite for the wip snapshot core.
#   nix shell nixpkgs#coreutils nixpkgs#git -c bash tests/wip.test.sh
# Run it under nix shell, not bare: wip.sh calls `date -Iseconds`, which BSD
# date (macOS) does not support. The generated `wip` binary gets GNU coreutils
# from its Nix PATH; a bare `bash tests/wip.test.sh` on ariane would not.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }

# Spy on every git invocation made by "$@" (typically a single wip_* call) by
# prepending a logging shim to PATH inside a subshell -- PATH/env changes
# never leak to the rest of the script. Each invocation's argv is appended as
# one line to $1; the real git (resolved once, up front) still runs, so
# behaviour is unaffected. Used where the SHA/ref a function produces cannot
# distinguish "took the fast path" from "did the work and got the same
# answer" -- e.g. a parentless commit whose message embeds a 1-second-
# resolution timestamp can be byte-identical on a retry whether or not a
# "nothing changed, skip the network" branch actually ran. Checking which
# git subcommands were (not) invoked observes the branch directly instead.
#
# Uses an explicit /tmp-rooted template for its own bookkeeping dir, NOT bare
# `mktemp -d` -- some callers (see the failure-path test below) deliberately
# break TMPDIR to make the *subject under test*'s mktemp fail, and spy_git's
# own setup must not fall over from the same override.
spy_git() {
  local logfile="$1"; shift
  local spydir realgit rc
  spydir="$(mktemp -d "/tmp/wip-spy.XXXXXXXXXX")" || {
    printf 'spy_git: mktemp failed, cannot install shim\n' >&2
    return 1
  }
  realgit="$(command -v git)"
  cat > "$spydir/git" <<SPY
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$logfile"
exec $realgit "\$@"
SPY
  chmod +x "$spydir/git"
  : > "$logfile"
  ( PATH="$spydir:$PATH" "$@" )
  rc=$?
  rm -rf "$spydir"
  return "$rc"
}

# Spy on ssh invocations made by "$@", simulating a connection that dies
# mid-transfer: forwards only the first $2 bytes of stdin into the (locally
# standing-in-for-remote) command, then reports failure regardless of that
# command's own exit status -- exactly what a dropped network connection
# looks like to the caller: the remote command may complete "successfully"
# based on truncated input, but the LOCAL ssh client, having failed to send
# the rest of $out into a now-dead channel, still reports non-zero. Used to
# prove wip_manifest_write's ssh publish path is atomic: a partial transfer
# must never reach the manifest's real destination, only a discardable
# remote_tmp that gets cleaned up.
#
# Same /tmp-rooted mktemp template as spy_git, for the same reason: callers
# may deliberately break TMPDIR for the subject under test.
spy_ssh_partial() {
  local logfile="$1" bytes="$2"; shift 2
  local spydir rc
  spydir="$(mktemp -d "/tmp/wip-sshspy.XXXXXXXXXX")" || {
    printf 'spy_ssh_partial: mktemp failed, cannot install shim\n' >&2
    return 1
  }
  cat > "$spydir/ssh" <<SPY
#!/usr/bin/env bash
# \$1 = remote host (ignored -- these tests stand a local directory in for
# the hub), \$2 = the remote command string.
printf '%s\n' "\$2" >> "$logfile"
head -c $bytes | bash -c "\$2"
exit 1
SPY
  chmod +x "$spydir/ssh"
  : > "$logfile"
  # `</dev/null` on the subshell, not decoration: the shim above pipes its stdin
  # through `head -c`, and wip_manifest_write's CLEANUP ssh call
  # (`ssh host "rm -f tmp"`) passes no stdin of its own, so the shim would read
  # the TEST SCRIPT's stdin and block forever whenever that is an open pipe with
  # no data -- measured: the suite hangs indefinitely when run with stdin
  # attached to a pipe rather than a tty or /dev/null. The publish call supplies
  # its own `< "$out"`, which overrides this and keeps the partial-transfer
  # simulation intact.
  ( PATH="$spydir:$PATH" "$@" </dev/null )
  rc=$?
  rm -rf "$spydir"
  return "$rc"
}

# Make a repo's index stat cache deliberately STALE, so that a `git status`
# which is missing --no-optional-locks will actually rewrite .git/index.
#
# This is the difference between an index assertion that means something and one
# that cannot fail. git only writes the index when refreshing it CHANGED it: if
# the cached stat data still matches the files on disk (a "warm" cache), even a
# fully unflagged `git status` leaves the file byte-identical. Backdating every
# working-tree file makes the cache mismatch, so git re-hashes, finds the
# content unchanged, and writes the refreshed stat back.
#
# Measured on git 2.54.0 against this suite's fixture repo:
#   warm cache  + `git status`                     -> index cksum SAME
#   stale cache + `git status`                     -> index cksum CHANGED
#   stale cache + `git --no-optional-locks status` -> index cksum SAME
# The first line is why the original "repo untouched: index" assertion was
# vacuous: it captured the cksum on the line directly after a `git status`.
#
# A backdated `-t` rather than a bare `touch`: a file whose mtime is the CURRENT
# second is "racily clean", which git handles by a different path. `-exec ... +`
# rather than xargs, so this works with BSD find on ariane as well as GNU.
#
# The timestamp ADVANCES on every call, and that is load-bearing when a block
# makes several index assertions in a row: a call that reused the same
# timestamp would be a no-op against an index that had already absorbed it
# (verified -- reverting the flag at BOTH sites then failed only the first
# assertion, because the first unflagged `git status` wrote the backdated stat
# into the index and re-staling to the same value left the cache warm).
STALE_N=0
stale_index() {
  STALE_N=$((STALE_N + 1))
  find "$1" -name .git -prune -o -type f \
    -exec touch -t "$(printf '2020010100%02d' "$STALE_N")" {} +
}

# A CONTENT manifest of a repo's .git: every regular file's path plus a checksum
# of its bytes, sorted. Two of these being equal is the strongest statement this
# suite can make about "wip did not touch the user's repo" -- it catches a
# rewritten index, a new ref, a stray lock file and an object that appeared,
# where the existing per-probe assertions (index cksum, for-each-ref, ...) each
# catch only one of those.
#
# Content, not mtimes: stale_index deliberately backdates the WORKING TREE, and
# git's own reads legitimately leave directory mtimes alone or not depending on
# the filesystem. LC_ALL=C so the ordering does not depend on the host's locale.
git_manifest() {
  ( cd "$1/.git" 2>/dev/null || return 0
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s %s\n' "$f" "$(cksum < "$f")"
    done )
}

setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export WIP_HOST="testhost"
  export WIP_REMOTE_HOST="unused"
  export WIP_LOCAL_HUB=1
  export WIP_REMOTE_PATH="$SANDBOX/hub"
  export WIP_ROOTS="work"
  export WIP_CACHE="$SANDBOX/cache"
  export WIP_STATE="$SANDBOX/state"
  mkdir -p "$HOME/work" "$WIP_REMOTE_PATH" "$WIP_CACHE" "$WIP_STATE"

  REPO="$HOME/work/demo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  git -C "$REPO" remote add origin https://github.com/acme/Demo-App.git
  printf 'node_modules/\n' > "$REPO/.gitignore"
  printf 'v1\n' > "$REPO/tracked.txt"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm init

  # Local bare repo standing in for gateway.
  git init --bare -q "$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
}
teardown() { rm -rf "$SANDBOX"; }

# shellcheck source=/dev/null
source "$HERE/../home/wip/wip.sh"

# --- slug --------------------------------------------------------------------
setup
check "slug: ssh and https origins agree" \
  "$(cd "$SANDBOX" && git -C "$REPO" remote set-url origin git@github.com:acme/Demo-App.git; wip_slug "$REPO")" \
  "github-com-acme-demo-app"
git -C "$REPO" remote set-url origin https://github.com/acme/Demo-App.git
check "slug: normalizes case and .git suffix" "$(wip_slug "$REPO")" "github-com-acme-demo-app"
teardown

# --- the hard guarantee ------------------------------------------------------
setup
printf 'dirty\n'      > "$REPO/tracked.txt"
printf 'new\n'        > "$REPO/untracked.txt"
mkdir -p "$REPO/node_modules"; printf 'junk\n' > "$REPO/node_modules/x"

BEFORE_REMOTES="$(git -C "$REPO" remote -v)"
BEFORE_BRANCHES="$(git -C "$REPO" branch -a)"
BEFORE_ALLREFS="$(git -C "$REPO" for-each-ref)"
BEFORE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
# The HARNESS's own probes go through --no-optional-locks as well. A plain
# `git status` here would warm the stat cache (and rewrite the index itself),
# which is exactly what made the index assertion below unfalsifiable before.
BEFORE_STATUS="$(git --no-optional-locks -C "$REPO" status --porcelain)"
stale_index "$REPO"
BEFORE_INDEX="$(cksum < "$REPO/.git/index")"

wip_snapshot "$REPO"

# Index FIRST, before any other probe can perturb it.
check "repo untouched: index"     "$(cksum < "$REPO/.git/index")"     "$BEFORE_INDEX"
check "repo untouched: remotes"   "$(git -C "$REPO" remote -v)"        "$BEFORE_REMOTES"
check "repo untouched: branches"  "$(git -C "$REPO" branch -a)"        "$BEFORE_BRANCHES"
check "repo untouched: all refs"  "$(git -C "$REPO" for-each-ref)"     "$BEFORE_ALLREFS"
check "repo untouched: HEAD"      "$(git -C "$REPO" rev-parse HEAD)"   "$BEFORE_HEAD"
check "repo untouched: status"    "$(git --no-optional-locks -C "$REPO" status --porcelain)" "$BEFORE_STATUS"

# --- snapshot content --------------------------------------------------------
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
SNAP="$(git -C "$BARE" rev-parse refs/heads/wip/testhost)"
check "snapshot: is parentless" "$(git -C "$BARE" rev-list --parents -n1 "$SNAP" | wc -w | tr -d ' ')" "1"
check "snapshot: captures dirty tracked file" \
  "$(git -C "$BARE" show "$SNAP:tracked.txt")" "dirty"
check "snapshot: captures untracked file" \
  "$(git -C "$BARE" show "$SNAP:untracked.txt")" "new"
check "snapshot: honours .gitignore" \
  "$(git -C "$BARE" ls-tree -r --name-only "$SNAP" | grep -c node_modules)" "0"
check "snapshot: records base commit" \
  "$(git -C "$BARE" log -1 --format=%s "$SNAP" | grep -c "base=$(git -C "$REPO" rev-parse --short HEAD)")" "1"

# --- idempotence and cleanup -------------------------------------------------
# NOTE: comparing the ref's SHA before/after a second call is NOT a valid way
# to prove the "tree unchanged, skip the network" branch ran: the commit
# message embeds `date -Iseconds` (1s resolution) and the commit is
# parentless, so a second, *unskipped* call within the same wall-clock second
# reproduces a byte-identical SHA regardless of whether the fast path fired.
# `git push` (and everything after the marker check) is only reachable past
# that branch, so its absence is what actually proves the skip happened.
spy_git "$SANDBOX/calls.log" wip_snapshot "$REPO"
check "snapshot: unchanged tree is not re-pushed" \
  "$(grep -wc push "$SANDBOX/calls.log")" "0"
check "snapshot: unchanged tree ref still matches" \
  "$(git -C "$BARE" rev-parse refs/heads/wip/testhost)" "$SNAP"

git -C "$REPO" checkout -q -- tracked.txt
rm -f "$REPO/untracked.txt"
wip_snapshot "$REPO"
check "snapshot: clean tree deletes the stale snapshot" \
  "$(git -C "$BARE" rev-parse --verify --quiet refs/heads/wip/testhost || echo gone)" "gone"
teardown

# --- failure path: temp index build must not clobber a good snapshot -------
# Regression test for: `GIT_INDEX_FILE=<unusable-path> git write-tree` does
# not itself fail -- it can silently return git's canonical empty-tree hash.
# Verified directly against real git: pointing TMPDIR at a nonexistent
# directory makes `mktemp` fail (idx becomes ""), `read-tree`/`add -A` then
# fail loudly ("unable to write new index file") but `write-tree` with that
# same empty GIT_INDEX_FILE silently succeeds with the empty-tree hash. An
# unguarded wip_snapshot would treat that as "the tree changed to empty" and
# force-push it over whatever good snapshot was already on the hub. Force
# exactly that failure mode (one of the three named in the finding: mktemp,
# read-tree, add -A) and confirm the hub ref, the marker, and the real
# .git/index all survive untouched, and that git push is never reached.
setup
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
MARKER="$WIP_STATE/$(wip_slug "$REPO").tree"

printf 'dirty\n' > "$REPO/tracked.txt"
wip_snapshot "$REPO"
GOOD_SNAP="$(git -C "$BARE" rev-parse refs/heads/wip/testhost)"
GOOD_MARKER="$(cat "$MARKER")"
GOOD_INDEX="$(cksum < "$REPO/.git/index")"

printf 'dirty again\n' > "$REPO/tracked.txt"   # tree now differs from the marker too
(
  export TMPDIR="$SANDBOX/no-such-dir"
  spy_git "$SANDBOX/calls.log" wip_snapshot "$REPO"
)
FAIL_RC=$?

check "snapshot: fails non-zero when the temp index build fails" "$FAIL_RC" "1"
check "snapshot: hub ref survives a failed run" \
  "$(git -C "$BARE" rev-parse refs/heads/wip/testhost)" "$GOOD_SNAP"
check "snapshot: marker untouched after a failed run" \
  "$(cat "$MARKER")" "$GOOD_MARKER"
check "snapshot: real .git/index untouched after a failed run" \
  "$(cksum < "$REPO/.git/index")" "$GOOD_INDEX"
check "snapshot: never reaches push on a failed run" \
  "$(grep -wc push "$SANDBOX/calls.log")" "0"
teardown

# --- discovery ---------------------------------------------------------------
setup
mkdir -p "$HOME/work/plain"                       # not a repo
ln -s /nonexistent "$HOME/work/dangling-link"     # symlink, must be skipped
check "discovery: finds repos, skips non-repos and symlinks" \
  "$(wip_repos | wc -l | tr -d ' ')" "1"
teardown

# --- manifest ----------------------------------------------------------------
setup
# A second repo that stays genuinely clean, alongside $REPO which is made
# dirty below -- both recorded in the SAME wip_manifest_write run, so the
# dirty=0/dirty=1 split proves the field is computed per-repo rather than a
# constant. (Regression: hardcoding dirty=1 for every repo left the old,
# single-repo version of this test passing.)
REPO2="$HOME/work/demo2"
mkdir -p "$REPO2"
git -C "$REPO2" init -q -b main
git -C "$REPO2" config user.email t@t; git -C "$REPO2" config user.name t
git -C "$REPO2" remote add origin https://github.com/acme/Clean-App.git
printf 'v1\n' > "$REPO2/tracked.txt"
git -C "$REPO2" add -A; git -C "$REPO2" commit -qm init

printf 'dirty\n' > "$REPO/tracked.txt"
wip_manifest_write
MAN="$WIP_REMOTE_PATH/_manifest/testhost.tsv"
check "manifest: written" "$([ -f "$MAN" ] && echo yes || echo no)" "yes"
check "manifest: one line per repo" "$(wc -l < "$MAN" | tr -d ' ')" "2"
check "manifest: records origin" \
  "$(awk -F'\t' -v s="$(wip_slug "$REPO")" '$1==s{print $2}' "$MAN")" \
  "https://github.com/acme/Demo-App.git"
check "manifest: records rel path" \
  "$(awk -F'\t' -v s="$(wip_slug "$REPO")" '$1==s{print $3}' "$MAN")" \
  "work/demo"
check "manifest: dirty repo recorded dirty=1" \
  "$(awk -F'\t' -v s="$(wip_slug "$REPO")" '$1==s{print $4}' "$MAN")" "1"
check "manifest: clean repo recorded dirty=0" \
  "$(awk -F'\t' -v s="$(wip_slug "$REPO2")" '$1==s{print $4}' "$MAN")" "0"
teardown

# --- manifest: read ------------------------------------------------------
setup
printf 'dirty\n' > "$REPO/tracked.txt"
wip_manifest_write
MAN_CONTENT="$(cat "$WIP_REMOTE_PATH/_manifest/testhost.tsv")"

check "manifest read: returns the published host's census" \
  "$(wip_manifest_read testhost)" "$MAN_CONTENT"

MAN_READ_OUT="$(wip_manifest_read nosuchhost)"; MAN_READ_RC=$?
check "manifest read: unpublished host returns empty output" "$MAN_READ_OUT" ""
check "manifest read: unpublished host exits zero" "$MAN_READ_RC" "0"
teardown

# --- manifest: ssh publish is atomic --------------------------------------
# Regression test for: wip_manifest_write's ssh branch used to stream
# straight into the live manifest path (`cat > <dest>`). A connection that
# died mid-transfer left the hub holding a truncated census where a
# complete one belonged. The fix splits the publish into two ssh calls --
# write to a remote temp path, then a SEPARATE `mv` attempted only if that
# write reported success -- so a failed first call, for any reason
# (including a connection that dies after forwarding only part of the
# data), never reaches the second: the hub keeps whatever it had before.
setup
REPO2="$HOME/work/demo2"
mkdir -p "$REPO2"
git -C "$REPO2" init -q -b main
git -C "$REPO2" config user.email t@t; git -C "$REPO2" config user.name t
git -C "$REPO2" remote add origin https://github.com/acme/Second-App.git
printf 'v1\n' > "$REPO2/tracked.txt"
git -C "$REPO2" add -A; git -C "$REPO2" commit -qm init

wip_manifest_write   # good baseline, over the real (local-hub) path
MAN="$WIP_REMOTE_PATH/_manifest/testhost.tsv"
GOOD_MANIFEST="$(cat "$MAN")"

# Force the NEXT write's content to differ from the good baseline, so a
# leaked truncated/partial write would be visibly detectable, not
# coincidentally identical to what was already there.
printf 'dirty again\n' > "$REPO/tracked.txt"
(
  export WIP_LOCAL_HUB=0
  spy_ssh_partial "$SANDBOX/ssh-calls.log" 10 wip_manifest_write
)
ATOMIC_FAIL_RC=$?

check "manifest atomicity: failed ssh publish returns non-zero" "$ATOMIC_FAIL_RC" "1"
check "manifest atomicity: hub keeps the previous complete manifest" \
  "$(cat "$MAN")" "$GOOD_MANIFEST"
check "manifest atomicity: no orphaned temp file" \
  "$(compgen -G "$MAN.*.tmp" 2>/dev/null | wc -l | tr -d ' ')" "0"
teardown

# --- shadow fetch ------------------------------------------------------------
setup
printf 'dirty\n' > "$REPO/tracked.txt"
wip_snapshot "$REPO"
# Pretend the snapshot came from the other host.
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
git -C "$BARE" update-ref refs/heads/wip/otherhost refs/heads/wip/testhost
git -C "$BARE" update-ref -d refs/heads/wip/testhost

BEFORE_ALLREFS="$(git -C "$REPO" for-each-ref)"
wip_fetch "$REPO"
check "fetch: real repo gains no refs" "$(git -C "$REPO" for-each-ref)" "$BEFORE_ALLREFS"
check "fetch: shadow holds the snapshot" \
  "$(git --git-dir="$(wip_shadow "$(wip_slug "$REPO")")" rev-parse --verify --quiet refs/wip/otherhost >/dev/null && echo yes || echo no)" \
  "yes"

# --- shadow diff ---------------------------------------------------------
# The real repo now diverges locally from the snapshot the other host left
# behind, so a correct diff must report exactly that one file -- not zero
# (which a broken read-tree-less diff would report by erroring out on a
# missing ref, and which an empty-index diff against an IDENTICAL worktree
# would also report, for the wrong reason: see wip_shadow_diff's comment).
printf 'diverged-locally\n' > "$REPO/tracked.txt"
check "fetch: shadow diff reports exactly the diverged file" \
  "$(wip_shadow_diff "$REPO" refs/wip/otherhost --name-only | tr -d ' ')" \
  "tracked.txt"
check "fetch: shadow diff exits non-zero when the ref is absent" \
  "$(wip_shadow_diff "$REPO" refs/wip/nosuchhost --name-only >/dev/null 2>&1; echo $?)" \
  "1"
teardown

# --- pull safety ref ---------------------------------------------------------
# The one path in this system that writes to a working tree, so the one path
# that can lose work.
setup
# main.sh ends in a dispatcher that runs at SOURCE time -- that is how the
# generated `wip` binary invokes it -- so hand it the read-only `notice` verb and
# discard the output. Sourcing rather than exec'ing main.sh as a subprocess is
# what lets these tests call wip_cmd_pull/wip_safety_ref directly and look at the
# working tree in between the gate and the destructive checkout.
# shellcheck source=/dev/null
source "$HERE/../home/wip/main.sh" notice >/dev/null 2>&1 || true

# The snapshot "the other host" left behind. It holds BOTH a tracked and an
# untracked file, because `wip pull` overwrites either -- and untracked scratch
# work is what an overwrite destroys with no trace anywhere in git.
printf 'from-other\n'    > "$REPO/tracked.txt"
printf 'other-scratch\n' > "$REPO/scratch.txt"
mkdir -p "$REPO/node_modules"; printf 'junk\n' > "$REPO/node_modules/x"
wip_snapshot "$REPO"
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
git -C "$BARE" update-ref refs/heads/wip/otherhost refs/heads/wip/testhost
git -C "$BARE" update-ref -d refs/heads/wip/testhost
wip_fetch "$REPO"
SHADOW="$(wip_shadow "$(wip_slug "$REPO")")"

# FIRST, while the worktree still matches the snapshot byte for byte AND the
# freshly fetched shadow has never had an index written to it (bare repo, only
# ever fetched into) -- exactly the state the fish cd-hook calls wip_notice in.
# There is nothing to announce. A notice here means wip_notice diffed that EMPTY
# index, which reports every path in the snapshot as deleted and would nag about
# a snapshot that is already applied. Order matters: any earlier wip_shadow_diff
# leaves a warm index behind and this assertion stops being able to see the bug.
check "notice: an identical tree produces no notice" "$(wip_notice "$REPO")" ""

# Now diverge: local work at the same two paths, which the pull must not lose.
printf 'my-local-work\n' > "$REPO/tracked.txt"
printf 'my-scratch\n'    > "$REPO/scratch.txt"
check "notice: reports the waiting snapshot from the other host" \
  "$(wip_notice "$REPO" | grep -c 'snapshot from otherhost')" "1"

wip_safety_ref "$REPO" "$SHADOW"
check "safety: ref created" \
  "$(git --git-dir="$SHADOW" rev-parse --verify --quiet refs/wip-safety/pre-pull >/dev/null && echo yes || echo no)" \
  "yes"
# The ref must capture the live WORKING TREE, not HEAD. Asserted against the
# ref's TREE rather than a file on disk on purpose: `git checkout <tree-ish> -- .`
# never DELETES paths that are absent from the tree-ish (verified), so a file
# that exists only locally is never at risk, and checking that it is still there
# after a restore would prove nothing.
check "safety: ref captures untracked work" \
  "$(git --git-dir="$SHADOW" ls-tree -r --name-only refs/wip-safety/pre-pull | grep -c '^scratch\.txt$')" "1"
check "safety: ref honours .gitignore" \
  "$(git --git-dir="$SHADOW" ls-tree -r --name-only refs/wip-safety/pre-pull | grep -c node_modules)" "0"
# Every blob the ref names has to be in the SHADOW's object store, or `wip undo`
# is a safety net that looks present and tears the moment it is used. An index
# seeded from the real repo's HEAD (instead of `add -A` against the live work
# tree) names blobs only the real repo has; measured, `write-tree` still exits 0
# and prints a hash for such an index but the tree never lands in the shadow, so
# assert the end state rather than any single step's exit code.
# Counting the blobs that ARE present (all three: .gitignore, tracked.txt,
# scratch.txt) rather than counting missing ones, because a ref whose tree object
# is itself absent makes ls-tree print nothing at all -- "found no missing
# objects" would then pass for the very worst case.
check "safety: the ref's blobs all live in the shadow" \
  "$(git --git-dir="$SHADOW" ls-tree -r refs/wip-safety/pre-pull | awk '{print $3}' \
     | while read -r o; do git --git-dir="$SHADOW" cat-file -e "$o" 2>/dev/null && echo present; done \
     | grep -c present)" "3"

# Force wip_safety_ref to fail FOR REAL -- an unwritable TMPDIR makes its mktemp
# fail, the same technique the snapshot failure-path test above uses -- and
# confirm the gate holds. This is the pair of assertions that would have caught
# the original bug, where a failed safety ref still let the destructive checkout
# run and the user was then told their previous tree had been saved.
check "safety: pull REFUSES when the safety ref cannot be written" \
  "$(cd "$REPO"; export TMPDIR="$SANDBOX/no-such-dir"; wip_cmd_pull --force <<<y >/dev/null 2>&1; echo $?)" \
  "1"
check "safety: a refused pull leaves the working tree untouched" \
  "$(cat "$REPO/tracked.txt")" "my-local-work"

# The destructive half of a real `wip pull`, this time with the safety ref in
# place.
git --git-dir="$SHADOW" --work-tree="$REPO" checkout refs/wip/otherhost -- .
check "safety: pull overwrites the tracked file"   "$(cat "$REPO/tracked.txt")" "from-other"
check "safety: pull overwrites the untracked file" "$(cat "$REPO/scratch.txt")" "other-scratch"

git --git-dir="$SHADOW" --work-tree="$REPO" checkout refs/wip-safety/pre-pull -- .
check "safety: undo restores the tracked file"   "$(cat "$REPO/tracked.txt")" "my-local-work"
check "safety: undo restores the untracked file" "$(cat "$REPO/scratch.txt")" "my-scratch"
# `^refs/wip` and not `^refs/wip/`: the safety ref now lives in a SECOND
# namespace (refs/wip-safety/), and this assertion has to cover both or half of
# what it guards against stops being visible.
check "safety: real repo still has no refs of its own" \
  "$(git -C "$REPO" for-each-ref --format='%(refname)' | grep -c '^refs/wip')" "0"
teardown

# --- `wip undo` has to survive the next timer tick ---------------------------
# Regression test for: wip_fetch fetches 'refs/heads/wip/*:refs/wip/*' with
# --prune, and the safety ref used to be written to refs/wip/pre-pull -- inside
# that same namespace, and never present on the hub. Every fetch therefore
# deleted it. Measured before the fix:
#
#   before fetch --prune:  refs/wip/otherhost  refs/wip/pre-pull
#   after  fetch --prune:  refs/wip/otherhost
#
# `wip pull` is the one operation in this tool that can destroy uncommitted
# work; it told the user `wip undo` would bring the tree back, and the next
# five-minute tick silently threw the safety net away.
#
# This drives the REAL sequence -- pull, tick, undo -- and asserts on the FILES.
# Asserting the ref merely exists would not be enough: a ref that survives but
# that `wip undo` no longer looks at, or whose blobs have been collected, passes
# an existence check and still loses the work. (main.sh was sourced above.)
setup
printf 'from-other\n'    > "$REPO/tracked.txt"
printf 'other-scratch\n' > "$REPO/scratch.txt"
wip_snapshot "$REPO"
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
git -C "$BARE" update-ref refs/heads/wip/otherhost refs/heads/wip/testhost
git -C "$BARE" update-ref -d refs/heads/wip/testhost
wip_fetch "$REPO"
SHADOW="$(wip_shadow "$(wip_slug "$REPO")")"

# Diverge locally: the work the pull is about to overwrite, tracked and
# untracked alike.
printf 'my-local-work\n' > "$REPO/tracked.txt"
printf 'my-scratch\n'    > "$REPO/scratch.txt"

( cd "$REPO" && wip_cmd_pull --force <<<y ) >/dev/null 2>&1
check "undo: the pull really did overwrite the tree first" \
  "$(cat "$REPO/tracked.txt")" "from-other"

# THE TICK. Nothing exotic: one ordinary fetch, the thing the timer runs on its
# own five minutes later whether or not the user does anything.
wip_fetch "$REPO"

UNDO_OUT="$( ( cd "$REPO" && wip_cmd_undo <<<y ) 2>&1 )"
check "undo: a fetch tick does not retire the pre-pull snapshot" \
  "$(printf '%s\n' "$UNDO_OUT" | grep -c 'no pre-pull snapshot')" "0"
check "undo: restores the tracked file after a fetch tick" \
  "$(cat "$REPO/tracked.txt")" "my-local-work"
check "undo: restores the untracked file after a fetch tick" \
  "$(cat "$REPO/scratch.txt")" "my-scratch"
# --prune must keep doing its job; the fix is the namespace, not a weaker fetch.
check "undo: the fetch tick still prunes withdrawn hub snapshots" \
  "$(git -C "$BARE" update-ref -d refs/heads/wip/otherhost; wip_fetch "$REPO"; \
     git --git-dir="$SHADOW" rev-parse --verify --quiet refs/wip/otherhost >/dev/null 2>&1 \
     && echo present || echo gone)" "gone"
teardown

# --- an origin-less census row must not shift `wip clone`'s columns ----------
# Regression test for: wip_missing parsed the manifest with
# `IFS=$'\t' read -r slug url rel dirty head`. TAB is one of the shell's IFS
# *whitespace* characters, so a RUN of tabs collapses into one delimiter -- and
# the url column is empty for every repo with no `origin`. Such a row arrived
# shifted one field left: `rel` was read as the url and the dirty flag as the
# rel, so `wip clone` offered `git clone work/originless ~/1` -- a relative path
# used as a clone URL, into a directory named after a boolean. Same trap and the
# same parameter-expansion fix as wip_manifest_snapshot_slugs; the two parsers
# have to stay consistent. (main.sh was sourced above.)
setup
mkdir -p "$WIP_REMOTE_PATH/_manifest"
HEADSHA="$(git -C "$REPO" rev-parse HEAD)"
{
  # Genuinely absent here, with a real origin: the one true clone candidate.
  printf 'github-com-acme-absent\thttps://github.com/acme/Absent.git\twork/absent\t1\t%s\n' "$HEADSHA"
  # ORIGIN-LESS -- two adjacent tabs. There is nothing to clone from, so this
  # row must vanish rather than be read one column over.
  printf 'work-originless\t\twork/originless\t1\t%s\n' "$HEADSHA"
  # Already present here; dropped on the -e test whatever the parse does.
  printf '%s\thttps://github.com/acme/Demo-App.git\twork/demo\t0\t%s\n' "$(wip_slug "$REPO")" "$HEADSHA"
  # Malformed: fewer than the five columns wip_manifest_write writes. Peeling
  # past the end of a string leaves it unchanged, so without an explicit
  # field-count guard the url would silently duplicate itself into the rel.
  printf 'short-row\thttps://github.com/acme/Short.git\n'
} > "$WIP_REMOTE_PATH/_manifest/otherhost.tsv"

check "missing: an origin-less row is dropped, not shifted into a candidate" \
  "$(wip_missing | cut -f1 | grep -c '^work-originless$')" "0"
check "missing: never puts a relative path where a clone URL belongs" \
  "$(wip_missing | cut -f2 | grep -c '^work/')" "0"
check "missing: a malformed short row is dropped" \
  "$(wip_missing | cut -f1 | grep -c '^short-row$')" "0"
check "missing: and the repo that really is absent is still reported, in full" \
  "$(wip_missing)" \
  "$(printf 'github-com-acme-absent\thttps://github.com/acme/Absent.git\twork/absent')"

# Through the verb the user actually types. `n` at the prompt, so nothing is
# cloned -- the listing is the whole point, since that listing is what was
# printing `work/originless  ->  ~/1`.
CLONE_LIST="$( ( cd "$SANDBOX" && wip_cmd_clone <<<n ) 2>&1 )"
check "clone: offers the missing repo by its real origin URL" \
  "$(printf '%s\n' "$CLONE_LIST" | grep -c '^  https://github.com/acme/Absent.git  ->  ~/work/absent$')" "1"
check "clone: and offers nothing else" \
  "$(printf '%s\n' "$CLONE_LIST" | grep -c ' ->  ~/')" "1"
check "clone: bare \`wip\` counts the same repos \`wip clone\` would offer" \
  "$( ( cd "$SANDBOX" && wip_cmd_status ) 2>/dev/null | grep -c 'otherhost has 1 repo(s) you do not')" "1"
teardown

# --- the hard guarantee, part 2: the verbs that run `git status` -------------
# The block near the top of this file only ever drives wip_snapshot, which never
# runs `git status` -- so it could not see the real breach: `git status`
# REWRITES .git/index whenever the stat cache is stale, and takes
# .git/index.lock to do it. wip_manifest_write does that against EVERY repo on
# EVERY five-minute tick, and wip_cmd_pull does it in its dirty-tree gate.
# Beyond breaking this tool's one hard promise, the lock races whatever git
# command the user happens to be running ("Unable to create '.git/index.lock':
# File exists"). `git --no-optional-locks status` is the fix.
#
# Every assertion here calls stale_index first (see its comment): without that
# the cache is warm, an unflagged `git status` is a no-op on the index file, and
# these assertions would pass whether the flag were present or not -- the same
# defect they exist to catch, one level up. Mutation-checked: reverting
# --no-optional-locks at either call site fails the matching assertion below.
# (main.sh was sourced in the section above.)
setup
printf 'dirty\n' > "$REPO/tracked.txt"
printf 'new\n'   > "$REPO/untracked.txt"

# A snapshot from "the other host", so wip_cmd_pull gets past its ref gate and
# actually reaches the `git status` under test.
wip_snapshot "$REPO"
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
git -C "$BARE" update-ref refs/heads/wip/otherhost refs/heads/wip/testhost
git -C "$BARE" update-ref -d refs/heads/wip/testhost
wip_fetch "$REPO"

stale_index "$REPO"
IDX="$(cksum < "$REPO/.git/index")"
wip_manifest_write >/dev/null 2>&1
check "no-lock: wip_manifest_write leaves .git/index byte-identical" \
  "$(cksum < "$REPO/.git/index")" "$IDX"
# Anti-vacuity: prove the call above actually did its work rather than bailing
# out early, which would make the assertion true for the wrong reason.
check "no-lock: ...and it really did publish a census" \
  "$([ -s "$WIP_REMOTE_PATH/_manifest/testhost.tsv" ] && echo yes || echo no)" "yes"

stale_index "$REPO"
IDX="$(cksum < "$REPO/.git/index")"
# Dirty tree, no --force: refuses at the status gate, so nothing destructive
# runs -- but the `git status` on the line under test does.
PULL_GATE_RC=0
( cd "$REPO" && wip_cmd_pull ) >/dev/null 2>&1 || PULL_GATE_RC=$?
check "no-lock: wip pull's dirty-tree gate leaves .git/index byte-identical" \
  "$(cksum < "$REPO/.git/index")" "$IDX"
check "no-lock: ...and the gate really did fire (it saw the dirty tree)" \
  "$PULL_GATE_RC" "1"

# The whole tick, exactly as the timer runs it: discovery, snapshot of every
# repo, then the manifest write. This is the statement that matters -- five
# minutes apart, forever, against the user's real repos.
printf 'dirtier\n' > "$REPO/tracked.txt"
stale_index "$REPO"
IDX="$(cksum < "$REPO/.git/index")"
wip_cmd_push --all >/dev/null 2>&1
check "no-lock: a whole \`wip push --all\` tick leaves .git/index byte-identical" \
  "$(cksum < "$REPO/.git/index")" "$IDX"
check "no-lock: ...and the tick really did push a new snapshot" \
  "$(git -C "$BARE" rev-parse --verify --quiet refs/heads/wip/testhost >/dev/null && echo yes || echo no)" \
  "yes"
teardown

# --- manifest: a failing `git status` is not "clean" -------------------------
# The dirty flag used to be decided purely by whether stdout was empty, with the
# exit status ignored -- so a repo git could not read reported dirty=0, i.e.
# "nothing waiting here", the exact opposite of the truth, to the other machine.
# A one-byte .git/index makes `git status` die ("index file smaller than
# expected") while `git rev-parse HEAD` still succeeds, so the repo gets past
# the loop's HEAD gate and reaches the line under test.
setup
REPO2="$HOME/work/demo2"
mkdir -p "$REPO2"
git -C "$REPO2" init -q -b main
git -C "$REPO2" config user.email t@t; git -C "$REPO2" config user.name t
git -C "$REPO2" remote add origin https://github.com/acme/Clean-App.git
printf 'v1\n' > "$REPO2/tracked.txt"
git -C "$REPO2" add -A; git -C "$REPO2" commit -qm init

printf 'x' > "$REPO/.git/index"     # corrupt, but HEAD still resolves
MAN_ERR="$SANDBOX/man.err"
wip_manifest_write 2>"$MAN_ERR"
MAN_RC=$?
MAN="$WIP_REMOTE_PATH/_manifest/testhost.tsv"

check "manifest: an unreadable repo is NOT recorded as clean" \
  "$(awk -F'\t' -v s="$(wip_slug "$REPO")" '$1==s{print $4}' "$MAN")" ""
check "manifest: the healthy repo is still published" \
  "$(awk -F'\t' -v s="$(wip_slug "$REPO2")" '$1==s{print $4}' "$MAN")" "0"
check "manifest: the omission is reported on stderr, naming the repo" \
  "$(grep -c "$REPO: git status failed" "$MAN_ERR")" "1"
check "manifest: and the write reports non-zero rather than a clean success" \
  "$MAN_RC" "1"
teardown

# --- batch resilience --------------------------------------------------------
# Off-LAN every push fails, so per-repo tolerance is load-bearing. This drives
# wip_cmd_push itself: an inlined copy of its loop would keep passing with the
# `|| true` deleted from main.sh, which is the thing under test.
# (main.sh was sourced in the section above.)
setup
printf 'dirty\n' > "$REPO/tracked.txt"
# A second repo whose push target is missing AND uncreatable, to force a failure.
BROKEN="$HOME/work/broken"; mkdir -p "$BROKEN"
git -C "$BROKEN" init -q -b main
git -C "$BROKEN" config user.email t@t; git -C "$BROKEN" config user.name t
git -C "$BROKEN" remote add origin https://github.com/acme/broken.git
printf 'x\n' > "$BROKEN/f.txt"
git -C "$BROKEN" add -A; git -C "$BROKEN" commit -qm init
printf 'dirty\n' > "$BROKEN/f.txt"
# Block bare-repo creation for the broken slug by planting a file where the
# directory would go.
: > "$WIP_REMOTE_PATH/$(wip_slug "$BROKEN").git"

# `set -euo pipefail` in the subshell: the generated `wip` binary runs under
# strict mode, so the tolerance has to hold there and not just under this
# suite's laxer settings.
( set -euo pipefail; wip_cmd_push --all ) >/dev/null 2>&1
BATCH_RC=$?
check "batch: survives a failing repo" "$BATCH_RC" "0"
check "batch: the healthy repo still got pushed" \
  "$(git -C "$WIP_REMOTE_PATH/$(wip_slug "$REPO").git" rev-parse --verify --quiet refs/heads/wip/testhost >/dev/null && echo yes || echo no)" \
  "yes"
# Order-independent proof the loop ran to completion: the manifest write is only
# reached after every repo has been attempted, however find happened to order
# them.
check "batch: the post-loop manifest write still ran" \
  "$([ -f "$WIP_REMOTE_PATH/_manifest/testhost.tsv" ] && echo yes || echo no)" "yes"
teardown

# --- status output -----------------------------------------------------------
# `wip` with no verb is the one the human types and the fish hook shows, so its
# lines have to actually BE lines. wip_notice ends with a newline but the command
# substitution in wip_cmd_status strips it, so wip_cmd_status has to put it back:
# without that, every waiting repo and then the shell prompt run together on a
# single line (measured).
setup
REPO2="$HOME/work/demo2"
mkdir -p "$REPO2"
git -C "$REPO2" init -q -b main
git -C "$REPO2" config user.email t@t; git -C "$REPO2" config user.name t
git -C "$REPO2" remote add origin https://github.com/acme/Second-App.git
printf 'v1\n' > "$REPO2/tracked.txt"
git -C "$REPO2" add -A; git -C "$REPO2" commit -qm init
git init --bare -q "$WIP_REMOTE_PATH/$(wip_slug "$REPO2").git"
for r in "$REPO" "$REPO2"; do
  printf 'from-other\n' > "$r/tracked.txt"
  wip_snapshot "$r"
  b="$WIP_REMOTE_PATH/$(wip_slug "$r").git"
  git -C "$b" update-ref refs/heads/wip/otherhost refs/heads/wip/testhost
  git -C "$b" update-ref -d refs/heads/wip/testhost
  printf 'mine\n' > "$r/tracked.txt"
  wip_fetch "$r"
done
# `wc -l` counts newlines, so an unterminated line counts 0 and this is exactly
# the discriminator.
check "status: in a repo, the notice is a complete line" \
  "$( ( cd "$REPO" && wip_cmd_status ) | wc -l | tr -d ' ')" "1"
check "status: outside a repo, one line per waiting repo" \
  "$( ( cd "$SANDBOX" && wip_cmd_status ) | grep -c 'snapshot from otherhost')" "2"
teardown

# --- pull/undo from a subdirectory -------------------------------------------
# A pathspec of `.` resolves against the CWD, so `git checkout <ref> -- .` run
# from a subdirectory applied only that subtree -- while the diff shown above the
# prompt, and the "wip: applied." after it, described the whole tree. Nothing was
# lost (the safety ref is built with `add -A`, which is CWD-independent), but the
# scope applied disagreed with the scope the user consented to. `:/` always means
# the top of the work tree.
setup
mkdir -p "$REPO/sub"
printf 'other-top\n'   > "$REPO/top.txt"
printf 'other-inner\n' > "$REPO/sub/inner.txt"
wip_snapshot "$REPO"
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
git -C "$BARE" update-ref refs/heads/wip/otherhost refs/heads/wip/testhost
git -C "$BARE" update-ref -d refs/heads/wip/testhost
printf 'mine-top\n'   > "$REPO/top.txt"
printf 'mine-inner\n' > "$REPO/sub/inner.txt"
wip_fetch "$REPO"

( cd "$REPO/sub" && wip_cmd_pull --force <<<y ) >/dev/null 2>&1
# The load-bearing one: top.txt lives OUTSIDE the directory the pull was run
# from, so `.` leaves it alone and `:/` applies it.
check "pull: from a subdirectory, applies files outside that subdirectory" \
  "$(cat "$REPO/top.txt")" "other-top"
check "pull: from a subdirectory, still applies that subdirectory" \
  "$(cat "$REPO/sub/inner.txt")" "other-inner"
( cd "$REPO/sub" && wip_cmd_undo <<<y ) >/dev/null 2>&1
check "undo: from a subdirectory, restores the whole tree" \
  "$(cat "$REPO/top.txt")" "mine-top"
teardown

# --- the snapshot's base commit ----------------------------------------------
# wip_snapshot has always written `base=<sha>` into the snapshot's own message,
# and for a long time NOTHING read it back: `grep -n 'base=' home/wip/*.sh`
# returned exactly one hit, the line that writes it. So `wip notice` compared
# two TREES and unconditionally said "run `wip pull`", never asking whether this
# machine even has the commit the snapshot sits on.
#
# When the other machine is dirty AND ahead, that advice is backwards. `wip pull`
# drops its files over this working tree while HEAD stays put, so every commit
# we are missing reappears as a mountain of uncommitted changes on the wrong
# base -- and the diffstat quoted in the notice is measuring two trees that are
# not comparable, so it is mostly counting commits `git pull` would have given
# for free. The answer is nearly always BOTH, IN ORDER.
#
# Three states, taken straight from `git merge-base --is-ancestor <base> HEAD`:
# 0 (we have it), 1 (it exists here but is not in our history), 128 (we cannot
# see it at all). Each gets its own notice naming its own next command, and the
# two that are not "0" gate `wip pull`. (main.sh was sourced above.)

# --- state 0: the base is an ancestor of HEAD --------------------------------
setup
printf 'from-other\n' > "$REPO/tracked.txt"
wip_snapshot "$REPO"                      # base= is this repo's own HEAD
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
git -C "$BARE" update-ref refs/heads/wip/otherhost refs/heads/wip/testhost
git -C "$BARE" update-ref -d refs/heads/wip/testhost
wip_fetch "$REPO"
SHADOW="$(wip_shadow "$(wip_slug "$REPO")")"
git -C "$REPO" checkout -q -- tracked.txt   # clean tree: only the base gate can refuse

# The subject line of whatever the shadow currently holds from otherhost. The
# parser is pure, so the tests feed it strings; this is how they get a REAL one.
snap_subject() { git --git-dir="$SHADOW" log -1 --format=%s refs/wip/otherhost; }

# The parser on its own, against literal subjects -- the malformed shapes are
# awkward to build as real commits and are exactly where this has to be right.
check "base: the parser reads base= out of a real subject line" \
  "$(wip_snapshot_base 'wip@artemis 2026-07-28T20:15:22-04:00 base=a1b2c3d branch=feat/x')" \
  "a1b2c3d"
check "base: base= as the last token still parses" \
  "$(wip_snapshot_base 'wip@artemis 2026-07-28T20:15:22-04:00 base=a1b2c3d')" "a1b2c3d"
check "base: a subject with no base= yields nothing" \
  "$(wip_snapshot_base 'wip@artemis 2026-07-28T20:15:22-04:00 branch=main')" ""
check "base: a non-hex base= is rejected rather than handed to git as an object" \
  "$(wip_snapshot_base 'wip@artemis 2026-07-28T20:15:22-04:00 base=not-a-sha branch=m')" ""
check "base: a base= too short to be a commit-ish is rejected" \
  "$(wip_snapshot_base 'wip@artemis 2026-07-28T20:15:22-04:00 base=ab branch=m')" ""

check "base: the recorded base is read back out of a real snapshot message" \
  "$(wip_snapshot_base "$(snap_subject)")" \
  "$(git -C "$REPO" rev-parse --short HEAD)"
check "base: a base we already have classifies as ok" \
  "$(wip_base_state "$REPO" "$(wip_snapshot_base "$(snap_subject)")")" "ok"

NOTICE_OK="$(wip_notice "$REPO")"
check "base ok: the notice still just says to run \`wip pull\`" \
  "$(printf '%s\n' "$NOTICE_OK" | grep -c 'run `wip pull`$')" "1"
check "base ok: ...and still carries the diffstat, which here is meaningful" \
  "$(printf '%s\n' "$NOTICE_OK" | grep -c 'file changed')" "1"
check "base ok: ...and sends nobody to git" \
  "$(printf '%s\n' "$NOTICE_OK" | grep -cE 'git (pull|fetch)')" "0"

# The age and the base now come out of the SAME `git log` (wip_snapshot_meta,
# one process instead of two on the cd-hook path), so pin that the two fields
# did not get swapped or mis-split in the process. Backdated three hours, which
# no other assertion here would notice.
AGED_TS="$(( $(date +%s) - 3 * 3600 ))"
AGED_SNAP="$(GIT_COMMITTER_DATE="$AGED_TS +0000" GIT_AUTHOR_DATE="$AGED_TS +0000" \
  git -C "$BARE" -c user.email=t@t -c user.name=t commit-tree \
  "$(git -C "$BARE" rev-parse 'refs/heads/wip/otherhost^{tree}')" \
  -m "wip@otherhost 2026-07-28T20:15:22-04:00 base=$(git -C "$REPO" rev-parse --short HEAD) branch=main")"
git -C "$BARE" update-ref refs/heads/wip/otherhost "$AGED_SNAP"
wip_fetch "$REPO"
check "base ok: the age still comes from the snapshot's own timestamp" \
  "$(wip_notice "$REPO" | grep -c '· 3 hr ago ·')" "1"
check "base ok: ...and the base read from that same commit still classifies ok" \
  "$(wip_base_state "$REPO" "$(wip_snapshot_base "$(snap_subject)")")" "ok"

# The control for the two-prompt discriminator further down: with an ok base a
# SINGLE `y` is enough, so a scenario where one `y` is NOT enough proves an
# extra confirmation exists rather than merely that the pull refused.
( cd "$REPO" && wip_cmd_pull <<<y ) >/dev/null 2>&1
check "base ok: \`wip pull\` is unchanged — one \`y\` applies the snapshot" \
  "$(cat "$REPO/tracked.txt")" "from-other"
teardown

# --- state 1: the base exists here but is not in our history -----------------
# The real shape of this: the other machine committed and pushed, we ran
# `git fetch` (so the object is here) but never merged. HEAD is behind.
setup
printf 'v2\n' > "$REPO/tracked.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm second
AHEAD_BASE="$(git -C "$REPO" rev-parse --short HEAD)"
printf 'from-other\n' > "$REPO/tracked.txt"
wip_snapshot "$REPO"                      # base= the second commit
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
git -C "$BARE" update-ref refs/heads/wip/otherhost refs/heads/wip/testhost
git -C "$BARE" update-ref -d refs/heads/wip/testhost
# Rewind: the second commit is still an OBJECT in this repo, it is simply no
# longer reachable from HEAD. That is exactly `fetched but not merged`.
git -C "$REPO" reset -q --hard HEAD~1
wip_fetch "$REPO"
SHADOW="$(wip_shadow "$(wip_slug "$REPO")")"

check "base ahead: a base off our history classifies as ahead, not unknown" \
  "$(wip_base_state "$REPO" "$AHEAD_BASE")" "ahead"

NOTICE_AHEAD="$(wip_notice "$REPO")"
check "base ahead: the notice names \`git pull\` first, then \`wip pull\`" \
  "$(printf '%s\n' "$NOTICE_AHEAD" | grep -c 'run `git pull` first, then `wip pull`')" "1"
check "base ahead: it names the base commit it is objecting to" \
  "$(printf '%s\n' "$NOTICE_AHEAD" | grep -c "$AHEAD_BASE")" "1"
# The number that used to be quoted here is mostly the commits `git pull` would
# hand over for free, so quoting it is worse than saying nothing.
check "base ahead: the incomparable diffstat is withheld" \
  "$(printf '%s\n' "$NOTICE_AHEAD" | grep -c 'file changed')" "0"
check "base ahead: and it does not end by telling you to just \`wip pull\`" \
  "$(printf '%s\n' "$NOTICE_AHEAD" | grep -c 'run `wip pull`$')" "0"

# `wip notice` runs on every `cd` through the fish hook, against the user's real
# repos, so the classifier reaching into the REAL repo (this is the one new call
# that does) must be read-only. `git merge-base` never refreshes the index the
# way `git status` does -- a full content manifest of .git is what pins it.
stale_index "$REPO"
GITMAN_BEFORE="$(git_manifest "$REPO")"
wip_notice "$REPO" >/dev/null 2>&1
check "base classify: a classifying notice leaves .git byte-identical" \
  "$(git_manifest "$REPO")" "$GITMAN_BEFORE"
# Anti-vacuity: the manifest above is only worth something if it can tell that
# .git changed at all.
git -C "$REPO" update-ref refs/wip-test-canary HEAD
check "base classify: ...and the manifest really can see a change to .git" \
  "$([ "$(git_manifest "$REPO")" = "$GITMAN_BEFORE" ] && echo same || echo differs)" "differs"
git -C "$REPO" update-ref -d refs/wip-test-canary

# --- `wip pull` must not silently apply onto the wrong base ------------------
# The tree is CLEAN here, so the dirty-tree gate cannot be what stops the pull
# -- whatever refuses is the base gate.
AHEAD_OUT="$( ( cd "$REPO" && wip_cmd_pull <<<n ) 2>&1 )"
check "pull ahead: it warns, in order, naming \`git pull\` before \`wip pull\`" \
  "$(printf '%s\n' "$AHEAD_OUT" | grep -c 'order that works is `git pull` first')" "1"
check "pull ahead: declining leaves the working tree alone" \
  "$(cat "$REPO/tracked.txt")" "v1"
# THE discriminator. One `y` applies the snapshot when the base is ok (asserted
# above); here it must not, because a SECOND, separate confirmation stands in
# front of the ordinary "Apply this snapshot?" prompt. Feeding `y` then `n`
# rather than relying on EOF keeps this independent of `read`'s behaviour at
# end of input.
( cd "$REPO" && wip_cmd_pull <<<$'y\nn' ) >/dev/null 2>&1
check "pull ahead: the wrong-order confirmation is SEPARATE from the apply prompt" \
  "$(cat "$REPO/tracked.txt")" "v1"
# --force means "my working tree is dirty, overwrite it". It must not double as
# consent to apply onto a base that is not in our history.
FORCE_OUT="$( ( cd "$REPO" && wip_cmd_pull --force <<<n ) 2>&1 )"
check "pull ahead: --force does not wave the wrong-order warning through" \
  "$(printf '%s\n' "$FORCE_OUT" | grep -c 'order that works is `git pull` first')" "1"
check "pull ahead: ...and --force alone still applies nothing" \
  "$(cat "$REPO/tracked.txt")" "v1"
# Consented to twice: it goes through, and every existing protection is still
# in place on the way.
( cd "$REPO" && wip_cmd_pull <<<$'y\ny' ) >/dev/null 2>&1
check "pull ahead: consented twice, the snapshot is applied" \
  "$(cat "$REPO/tracked.txt")" "from-other"
check "pull ahead: ...and the pre-pull safety ref was still written first" \
  "$(git --git-dir="$SHADOW" rev-parse --verify --quiet refs/wip-safety/pre-pull >/dev/null && echo yes || echo no)" \
  "yes"
( cd "$REPO" && wip_cmd_undo <<<y ) >/dev/null 2>&1
check "pull ahead: ...and \`wip undo\` really brings the old tree back" \
  "$(cat "$REPO/tracked.txt")" "v1"

# Gate ordering: a refusal the user cannot argue with must come before a
# question. A dirty tree with no --force refuses outright and never prompts.
printf 'my-local-work\n' > "$REPO/tracked.txt"
DIRTY_OUT="$( ( cd "$REPO" && wip_cmd_pull <<<y ) 2>&1 )"
check "pull ahead: a dirty tree still refuses outright, before any prompt" \
  "$(printf '%s\n' "$DIRTY_OUT" | grep -c 'Apply it anyway')" "0"
check "pull ahead: ...and that refusal leaves the local work in place" \
  "$(cat "$REPO/tracked.txt")" "my-local-work"
teardown

# --- state 128: the base names no object we have -----------------------------
# We have not fetched it, or the other machine never pushed the commit. Applying
# a tree whose base is invisible is the worst version of this: there is nothing
# to reason against, so `wip pull` refuses outright.
setup
printf 'from-other\n' > "$REPO/tracked.txt"
wip_snapshot "$REPO"
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
UNKNOWN_BASE="0123456789abcdef0123456789abcdef01234567"
SNAP_TREE="$(git -C "$BARE" rev-parse 'refs/heads/wip/testhost^{tree}')"
FAKE_SNAP="$(git -C "$BARE" -c user.email=t@t -c user.name=t commit-tree "$SNAP_TREE" \
  -m "wip@otherhost 2026-07-28T20:15:22-04:00 base=$UNKNOWN_BASE branch=main")"
git -C "$BARE" update-ref refs/heads/wip/otherhost "$FAKE_SNAP"
git -C "$BARE" update-ref -d refs/heads/wip/testhost
wip_fetch "$REPO"
SHADOW="$(wip_shadow "$(wip_slug "$REPO")")"
git -C "$REPO" checkout -q -- tracked.txt   # clean tree, as above

check "base unknown: an invisible base classifies as unknown, not ahead" \
  "$(wip_base_state "$REPO" "$UNKNOWN_BASE")" "unknown"

NOTICE_UNKNOWN="$(wip_notice "$REPO")"
check "base unknown: the notice says the base is unknown here" \
  "$(printf '%s\n' "$NOTICE_UNKNOWN" | grep -c "base $UNKNOWN_BASE is unknown here")" "1"
check "base unknown: it sends you to \`git fetch\`, not \`git pull\`" \
  "$(printf '%s\n' "$NOTICE_UNKNOWN" | grep -c 'run `git fetch` first')" "1"
check "base unknown: ...and never to \`wip pull\`" \
  "$(printf '%s\n' "$NOTICE_UNKNOWN" | grep -c 'wip pull')" "0"

UNKNOWN_RC=0
UNKNOWN_OUT="$( ( cd "$REPO" && wip_cmd_pull <<<y ) 2>&1 )" || UNKNOWN_RC=$?
check "pull unknown: refuses, non-zero" "$UNKNOWN_RC" "1"
check "pull unknown: ...saying so, and naming \`git fetch\`" \
  "$(printf '%s\n' "$UNKNOWN_OUT" | grep -c 'Run `git fetch` first')" "1"
check "pull unknown: ...and the working tree is untouched" \
  "$(cat "$REPO/tracked.txt")" "v1"
# The escape hatch has to exist, or a genuinely stuck user has none.
( cd "$REPO" && wip_cmd_pull --force <<<y ) >/dev/null 2>&1
check "pull unknown: --force is the way past it" \
  "$(cat "$REPO/tracked.txt")" "from-other"
teardown

# --- a message with no readable base= must not break anything ----------------
# Compatibility, and the reason `none` is a state of its own. A snapshot written
# by an older `wip`, or a hand-made ref, has no base to classify -- that is not
# evidence of divergence, so the notice and the pull behave exactly as they did
# before the classifier existed. Refusing here would strand the work instead.
setup
printf 'from-other\n' > "$REPO/tracked.txt"
wip_snapshot "$REPO"
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
SNAP_TREE="$(git -C "$BARE" rev-parse 'refs/heads/wip/testhost^{tree}')"
NOBASE_SNAP="$(git -C "$BARE" -c user.email=t@t -c user.name=t commit-tree "$SNAP_TREE" \
  -m "wip@otherhost 2026-07-28T20:15:22-04:00 branch=main")"
git -C "$BARE" update-ref refs/heads/wip/otherhost "$NOBASE_SNAP"
git -C "$BARE" update-ref -d refs/heads/wip/testhost
wip_fetch "$REPO"
SHADOW="$(wip_shadow "$(wip_slug "$REPO")")"
git -C "$REPO" checkout -q -- tracked.txt

check "base none: a message with no base= reads as no base at all" \
  "$(wip_snapshot_base "$(snap_subject)")" ""
check "base none: which classifies as none, not as unknown" \
  "$(wip_base_state "$REPO" "")" "none"
check "base none: the notice falls back to the plain one" \
  "$(wip_notice "$REPO" | grep -c 'run `wip pull`$')" "1"
( cd "$REPO" && wip_cmd_pull <<<y ) >/dev/null 2>&1
check "base none: and \`wip pull\` still applies on a single \`y\`" \
  "$(cat "$REPO/tracked.txt")" "from-other"

# A base= that is not plausible hex must read as absent too, rather than being
# handed to git and coming back 128 -- which would report a corrupt message to
# the user as "the other machine has a commit you are missing".
GARBAGE_SNAP="$(git -C "$BARE" -c user.email=t@t -c user.name=t commit-tree "$SNAP_TREE" \
  -m "wip@otherhost 2026-07-28T20:15:22-04:00 base=not-a-sha branch=main")"
git -C "$BARE" update-ref refs/heads/wip/otherhost "$GARBAGE_SNAP"
wip_fetch "$REPO"
check "base none: a malformed base= is not passed off to git as an object" \
  "$(wip_snapshot_base "$(snap_subject)")" ""
teardown

# --- fetch: one census read, then only the repos that have a snapshot --------
# `wip fetch` used to call wip_fetch on EVERY local repo unconditionally: one
# TCP connection and one public-key authentication per repo. Measured on artemis
# 2026-07-28, straight out of the timer's journal: 36 connections a tick, 32 of
# them ending in "fetch from hub failed" because the other machine had never
# published those slugs, every five minutes, each one an approval prompt.
#
# The other host's census already says which slugs have a snapshot waiting, so
# one round-trip answers it for the whole batch. These assertions pin both
# halves: WHICH repos get fetched, and -- by routing git's own transport through
# the same ssh stub -- how many connections that actually costs.
setup
export WIP_LOCAL_HUB=0
SSHLOG="$SANDBOX/ssh.log"; : > "$SSHLOG"
cat > "$SANDBOX/ssh-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SSHLOG"
exec bash -c "\${*: -1}"
STUB
chmod +x "$SANDBOX/ssh-stub"
export WIP_SSH="$SANDBOX/ssh-stub"
# git's transport through the SAME stub, so a per-repo `git fetch` shows up as
# the connection it really is. Without this the count below could only see the
# direct ssh calls -- i.e. it would miss the entire thing under test.
export GIT_SSH_COMMAND="$SANDBOX/ssh-stub"

REPO2="$HOME/work/demo2"; REPO3="$HOME/work/demo3"
# REPO4 deliberately has NO origin, so wip_slug falls back to the $HOME-relative
# path and its census row carries an EMPTY url column. See the census below.
REPO4="$HOME/work/demo4"
for r in "$REPO2" "$REPO3" "$REPO4"; do
  mkdir -p "$r"
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  printf 'v1\n' > "$r/tracked.txt"
  git -C "$r" add -A; git -C "$r" commit -qm init
done
git -C "$REPO2" remote add origin https://github.com/acme/Second-App.git
git -C "$REPO3" remote add origin https://github.com/acme/Third-App.git
# Bare repos for all of them, so a wrongly-unfiltered fetch would SUCCEED rather
# than erroring out. The filter has to be what stops the connection, not a
# missing repo on the hub.
for r in "$REPO2" "$REPO3" "$REPO4"; do git init --bare -q "$WIP_REMOTE_PATH/$(wip_slug "$r").git"; done
SHADOW1="$(wip_shadow "$(wip_slug "$REPO")")"

# --- nothing published yet: the state both machines were actually in ---------
: > "$SSHLOG"
wip_cmd_fetch_all
check "fetch batch: an unpublished slug costs no connection at all" \
  "$(grep -c 'git-upload-pack' "$SSHLOG")" "0"
# The whole tick's remaining cost: the reachability probe and ONE census read.
# Both are per-tick, not per-repo, and multiplexing collapses them onto a single
# authentication.
check "fetch batch: an idle tick is the probe plus one census read, nothing more" \
  "$(grep -c . "$SSHLOG")" "2"
check "fetch batch: no shadow repo is created for a slug nobody published" \
  "$(ls "$WIP_CACHE" | wc -l | tr -d ' ')" "0"

# --- one slug published dirty, one clean, one absent from the census ---------
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
printf 'from-other\n' > "$REPO/tracked.txt"
( export WIP_LOCAL_HUB=1; wip_snapshot "$REPO" )
git -C "$BARE" update-ref refs/heads/wip/otherhost refs/heads/wip/testhost
git -C "$BARE" update-ref -d refs/heads/wip/testhost
printf 'mine\n' > "$REPO/tracked.txt"

MANOTHER="$WIP_REMOTE_PATH/_manifest/otherhost.tsv"
mkdir -p "$WIP_REMOTE_PATH/_manifest"
write_other_census() {   # $1 = dirty flag for demo, $2 = dirty flag for demo4
  {
    printf '%s\thttps://github.com/acme/Demo-App.git\twork/demo\t%s\t%s\n' \
      "$(wip_slug "$REPO")" "$1" "$(git -C "$REPO" rev-parse HEAD)"
    printf '%s\thttps://github.com/acme/Second-App.git\twork/demo2\t0\t%s\n' \
      "$(wip_slug "$REPO2")" "$(git -C "$REPO2" rev-parse HEAD)"
    # An ORIGIN-LESS repo: wip_manifest_write emits an empty url column for it,
    # i.e. two adjacent tabs. TAB is IFS whitespace, so the obvious
    # `IFS=$'\t' read -r slug url rel dirty head` collapses them, shifts every
    # field left by one and reads the head SHA as the dirty flag -- which drops
    # exactly the repos that exist on ONLY the other machine. Measured against
    # the live gateway census: 2 of 7 waiting snapshots silently skipped.
    printf '%s\t\twork/demo4\t%s\t%s\n' \
      "$(wip_slug "$REPO4")" "$2" "$(git -C "$REPO4" rev-parse HEAD)"
  } > "$MANOTHER"
}
write_other_census 1 1

: > "$SSHLOG"
wip_cmd_fetch_all
check "fetch batch: fetches the slug the other host published a snapshot for" \
  "$(git --git-dir="$SHADOW1" rev-parse --verify --quiet refs/wip/otherhost >/dev/null 2>&1 \
     && echo yes || echo no)" "yes"
check "fetch batch: skips a slug the other host reports clean" \
  "$([ -d "$(wip_shadow "$(wip_slug "$REPO2")")" ] && echo yes || echo no)" "no"
check "fetch batch: skips a slug missing from the census entirely" \
  "$([ -d "$(wip_shadow "$(wip_slug "$REPO3")")" ] && echo yes || echo no)" "no"
# The origin-less row. A repo with no `origin` exists on ONE machine by
# definition, so its snapshot is the only copy of that work there is -- the
# worst possible row to drop, and the one the tab-collapsing parse drops.
check "fetch batch: a published row with an empty url column is not skipped" \
  "$([ -d "$(wip_shadow "$(wip_slug "$REPO4")")" ] && echo yes || echo no)" "yes"
check "fetch batch: one per-repo connection each for the two published repos" \
  "$(grep -c 'git-upload-pack' "$SSHLOG")" "2"
# The point of hoisting the read into the batch: three repos, one census read.
# Per-repo it would cost the very round-trip the filter exists to save.
check "fetch batch: the census is read once for the batch, not once per repo" \
  "$(grep -c '_manifest/otherhost.tsv' "$SSHLOG")" "1"

# --- a WITHDRAWN snapshot must not be stranded in the shadow -----------------
# The other host commits its work: hub ref deleted, census flips to dirty=0. A
# census-only filter would never look at that slug again, leaving a stale
# refs/wip/otherhost that `wip notice` keeps announcing and `wip pull` offers to
# apply. One more fetch prunes it, and then it drops out for good.
git -C "$BARE" update-ref -d refs/heads/wip/otherhost
write_other_census 0 0
: > "$SSHLOG"
wip_cmd_fetch_all
check "fetch batch: a withdrawn snapshot is still fetched once, so --prune can retire it" \
  "$(grep -c 'git-upload-pack' "$SSHLOG")" "1"
check "fetch batch: and the stale shadow ref is actually gone afterwards" \
  "$(git --git-dir="$SHADOW1" rev-parse --verify --quiet refs/wip/otherhost >/dev/null 2>&1 \
     && echo present || echo gone)" "gone"
: > "$SSHLOG"
wip_cmd_fetch_all
check "fetch batch: once retired, that slug stops costing a connection" \
  "$(grep -c 'git-upload-pack' "$SSHLOG")" "0"

# The filter belongs to the BATCH. wip_fetch's contract is "you hand me a repo,
# I fetch it" -- putting the census check inside it would cost one round-trip
# per repo and break every single-repo caller.
: > "$SSHLOG"
wip_fetch "$REPO3"
check "fetch: a direct single-repo fetch is still unconditional" \
  "$(grep -c 'git-upload-pack' "$SSHLOG")" "1"
unset GIT_SSH_COMMAND WIP_SSH
teardown

# --- WIP_SSH indirection -----------------------------------------------------
# Every ssh call has to go through wip_hub_ssh. GIT_SSH_COMMAND covers git's own
# push/fetch but nothing covers a direct `ssh`, so a bare one would miss both the
# dedicated hub key and the shared connection. These assertions drive the four
# non-git call sites with WIP_SSH pointed at a stub; each one FAILS if that site
# reaches for bare `ssh`, because the real ssh cannot reach "unused".
setup
export WIP_LOCAL_HUB=0            # take the ssh path, not the local-directory one
SSHLOG="$SANDBOX/ssh.log"; : > "$SSHLOG"
cat > "$SANDBOX/ssh-stub" <<STUB
#!/usr/bin/env bash
# Stand-in for ssh: record the argv, then run the remote command locally. The
# command is always the LAST argument, whatever options precede it.
printf '%s\n' "\$*" >> "$SSHLOG"
exec bash -c "\${*: -1}"
STUB
chmod +x "$SANDBOX/ssh-stub"
export WIP_SSH="$SANDBOX/ssh-stub"
# The hub key and the shared connection, which home/wip.nix sets from
# kyle.wip.identityFile and its controlPath. Both are per-CALL-SITE: a call site
# that skips wip_hub_ssh gets neither, which costs a whole extra handshake (and,
# with the agent back in play, an approval prompt) that nothing else would
# notice. Hence the counts below, which are the line count of the whole log.
export WIP_SSH_IDENTITY="$SANDBOX/wip_hub_ed25519"
export WIP_SSH_CONTROL="$SANDBOX/cm/%C"

printf 'dirty\n' > "$REPO/tracked.txt"
HUB_UP="$(wip_hub_up && echo up || echo down)"
rm -rf "$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"   # setup made this one locally
wip_ensure_bare "$(wip_slug "$REPO")"
wip_manifest_write
MAN_BACK="$(wip_manifest_read testhost)"

check "ssh: wip_hub_up probes through WIP_SSH" "$HUB_UP" "up"
check "ssh: wip_ensure_bare creates the hub repo through WIP_SSH" \
  "$([ -d "$WIP_REMOTE_PATH/$(wip_slug "$REPO").git" ] && echo yes || echo no)" "yes"
check "ssh: wip_manifest_write publishes through WIP_SSH" \
  "$([ -f "$WIP_REMOTE_PATH/_manifest/testhost.tsv" ] && echo yes || echo no)" "yes"
# Matching against the census CONTENT, not against `cat` of the same file: with a
# bare `ssh` here both sides would be empty and an equality check would pass for
# the broken case.
check "ssh: wip_manifest_read reads the census back through WIP_SSH" \
  "$(printf '%s\n' "$MAN_BACK" | grep -c "$(wip_slug "$REPO")")" "1"
# 5 invocations: the probe, the bare-repo init, the manifest write and its
# separate mv, and the read. If you add an ssh call site, this number changes on
# purpose -- that is the point of pinning it.
check "ssh: the stub recorded every ssh call site (no bare ssh left)" \
  "$(grep -c . "$SSHLOG")" "5"
# 5, i.e. every line in the log. Multiplexing that misses one call site is a
# whole extra TCP connection and public-key authentication per tick.
check "ssh: every hub call site rides the shared connection" \
  "$(grep -cF -e "-o ControlMaster=auto -o ControlPath=$SANDBOX/cm/%C -o ControlPersist=60" "$SSHLOG")" "5"
# IdentitiesOnly is half the assertion on purpose: with -i alone, ssh still
# offers the agent's keys first (ariane's ~/.ssh/config sets IdentityAgent for
# `Host *`), the agent signs, and the approval prompt is back.
check "ssh: every hub call site authenticates with the dedicated key, not the agent" \
  "$(grep -cF -e "-i $SANDBOX/wip_hub_ed25519 -o IdentitiesOnly=yes" "$SSHLOG")" "5"
# ssh does not create the ControlPath's parent, and a missing one is a fatal
# bind() error rather than a fallback -- it would take out every hub operation.
check "ssh: the control socket's directory is created (ssh will not do it)" \
  "$([ -d "$SANDBOX/cm" ] && echo yes || echo no)" "yes"

# The remaining two call sites are wip_manifest_write's cleanup, reached only
# when a publish fails -- and they are `2>/dev/null || true`, so nothing above can
# see them. Measured: reverting just those two to bare `ssh` failed no assertion
# at all. So drive a failing publish as well; the tmp-file removal must also go
# through WIP_SSH, or on artemis a failed publish silently orphans a file on the
# hub instead of cleaning up.
: > "$SSHLOG"
cat > "$SANDBOX/ssh-stub-fail" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SSHLOG"
case "\${*: -1}" in *"cat > "*) exit 1 ;; esac
exec bash -c "\${*: -1}"
STUB
chmod +x "$SANDBOX/ssh-stub-fail"
( export WIP_SSH="$SANDBOX/ssh-stub-fail"; wip_manifest_write ) >/dev/null 2>&1
check "ssh: the failed-publish cleanup goes through WIP_SSH too" \
  "$(grep -c 'rm -f' "$SSHLOG")" "1"
# 2 = the failed publish and its cleanup, i.e. every line here too.
check "ssh: the failed-publish path rides the shared connection as well" \
  "$(grep -cF -e '-o ControlMaster=auto' "$SSHLOG")" "2"
unset WIP_SSH WIP_SSH_IDENTITY WIP_SSH_CONTROL
teardown

# --- the hub key and multiplexing are opt-in ---------------------------------
# Neither may be invented by wip.sh out of thin air. The suite drives a local
# directory as the hub and stubs ssh where it does not, and a hardcoded
# ControlPath would put a socket somewhere unexpected on any machine that merely
# sourced this file. Unset means absent, not defaulted.
setup
export WIP_LOCAL_HUB=0
SSHLOG="$SANDBOX/ssh.log"; : > "$SSHLOG"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %s\nexit 0\n' "$SSHLOG" > "$SANDBOX/ssh-plain"
chmod +x "$SANDBOX/ssh-plain"
( export WIP_SSH="$SANDBOX/ssh-plain"; wip_hub_up ) >/dev/null 2>&1
check "ssh: the probe still happens with neither configured" \
  "$(grep -c . "$SSHLOG")" "1"
check "ssh: no ControlPath is invented when none is configured" \
  "$(grep -cF -e 'ControlMaster' "$SSHLOG")" "0"
check "ssh: no identity is invented when none is configured" \
  "$(grep -cF -e 'IdentitiesOnly' "$SSHLOG")" "0"
teardown

# --- an unresolvable WIP_SSH is a misconfiguration, not a sleeping hub --------
# The failure this pins down: `ssh.exe` is a bare name that only reaches PATH via
# home.sessionPath, which a systemd user unit never sources. The probe's stderr
# goes to /dev/null (an absent LAN-only hub is normal and must stay quiet), and
# that also swallowed the shell's "command not found" -- so `wip push --all`
# exited 0 with NO output and the timer pushed nothing, silently, forever.
# It passes by hand, because an interactive shell does resolve ssh.exe.
setup
export WIP_LOCAL_HUB=0            # take the ssh path, not the local-directory one

MISSING_ERR="$SANDBOX/missing.err"
( export WIP_SSH="definitely-not-a-real-ssh-binary"; wip_hub_up ) 2>"$MISSING_ERR"
MISSING_STATUS=$?
# Status 127 alone is NOT the fix -- the old code already returned it, and the
# caller swallowed it anyway. Pinned so the exit path keeps reporting it; the
# next assertion is the one that flips.
check "ssh-missing: wip_hub_up surfaces the shell's 127" \
  "$MISSING_STATUS" "127"
check "ssh-missing: the diagnostic names the command that would not resolve" \
  "$(grep -c 'definitely-not-a-real-ssh-binary' "$MISSING_ERR")" "1"

# The other half of the distinction, and the anti-regression for the fix above:
# a hub that is merely ASLEEP must stay silent and must NOT abort. 255 is what
# real ssh returns when it cannot connect.
cat > "$SANDBOX/ssh-unreachable" <<'STUB'
#!/usr/bin/env bash
exit 255
STUB
chmod +x "$SANDBOX/ssh-unreachable"
ASLEEP_ERR="$SANDBOX/asleep.err"
( export WIP_SSH="$SANDBOX/ssh-unreachable"; wip_hub_up ) 2>"$ASLEEP_ERR"
ASLEEP_STATUS=$?
check "ssh-missing: an unreachable hub still returns non-zero" "$ASLEEP_STATUS" "255"
check "ssh-missing: an unreachable hub stays quiet (no diagnostic)" \
  "$(wc -c <"$ASLEEP_ERR" | tr -d ' ')" "0"

# 255 AGAIN -- but from a rejected key rather than an absent host. OpenSSH
# returns 255 for both, so an allow-list keyed on the exit status alone reads a
# broken agent as "hub away" and the timer runs every five minutes forever
# pushing nothing and logging nothing. Third route to the same silent-timer bug
# after 127 and 126, and the only one that reproduced on the real machine: this
# is verbatim what artemis's probe printed from a systemd user unit, where the
# Windows 1Password agent would not sign for gateway's key. The stderr TEXT is
# the only thing that separates the two cases.
cat > "$SANDBOX/ssh-authfail" <<'STUB'
#!/usr/bin/env bash
cat >&2 <<'MSG'
sign_and_send_pubkey: signing failed for ED25519 "SHA256_PoAOWNkQ.pub" from agent: communication with agent failed
kyle@10.11.12.105: Permission denied (publickey,password,keyboard-interactive).
MSG
exit 255
STUB
chmod +x "$SANDBOX/ssh-authfail"
AUTH_ERR="$SANDBOX/auth.err"
( export WIP_SSH="$SANDBOX/ssh-authfail"; wip_hub_up ) 2>"$AUTH_ERR"
AUTH_STATUS=$?
# Pinning only -- 255 is what a rejected key AND a sleeping hub both produce, so
# this assertion cannot tell them apart. The three below are the ones that can.
check "ssh-auth: a rejected key still surfaces ssh's own 255" \
  "$AUTH_STATUS" "255"
check "ssh-auth: it says the fault is local, not that the hub is away" \
  "$(grep -c 'not a sleeping hub' "$AUTH_ERR")" "1"
check "ssh-auth: the diagnostic quotes what ssh actually said" \
  "$(grep -c 'Permission denied' "$AUTH_ERR")" "1"

# The other side of the classification, and the assertion that stops the fix
# above from turning an ordinary off-LAN laptop into a five-minute noise
# generator. These are real OpenSSH connection-failure messages; every one of
# them must stay silent and must NOT abort.
QUIET_FAILURES=$'ssh: connect to host gateway port 22: No route to host\nssh: connect to host 10.11.12.105 port 22: Operation timed out\nssh: connect to host gateway port 22: Connection refused\nssh: Could not resolve hostname gateway: nodename nor servname provided\nkex_exchange_identification: Connection closed by remote host'
cat > "$SANDBOX/ssh-quiet" <<STUB
#!/usr/bin/env bash
cat "$SANDBOX/quiet.msg" >&2
exit 255
STUB
chmod +x "$SANDBOX/ssh-quiet"
QUIET_NOISE=0; QUIET_LOUD=0
while IFS= read -r msg; do
  printf '%s\n' "$msg" > "$SANDBOX/quiet.msg"
  ( export WIP_SSH="$SANDBOX/ssh-quiet"; wip_hub_up ) 2>"$SANDBOX/quiet.err"
  [ $? -eq 255 ] || QUIET_LOUD=$((QUIET_LOUD+1))
  [ -s "$SANDBOX/quiet.err" ] && QUIET_NOISE=$((QUIET_NOISE+1))
done <<< "$QUIET_FAILURES"
check "ssh-auth: genuine connection failures stay silent (the normal off-LAN case)" \
  "$QUIET_NOISE" "0"
check "ssh-auth: genuine connection failures still return 255 without aborting" \
  "$QUIET_LOUD" "0"

# End to end through the dispatcher, under the generated binary's `set -euo
# pipefail`, exactly as the timer invokes it. Asserting on wip_hub_up alone is
# not enough: the silence came from wip_cmd_push's `wip_hub_up || return 0`.
AUTH_PUSH_OUT="$(
  ( set -euo pipefail
    export WIP_LOCAL_HUB=0
    export WIP_SSH="$SANDBOX/ssh-authfail"
    # shellcheck source=/dev/null
    source "$HERE/../home/wip/wip.sh"
    # shellcheck source=/dev/null
    source "$HERE/../home/wip/main.sh" push --all ) 2>&1
)"
AUTH_PUSH_STATUS=$?
check "ssh-auth: \`wip push --all\` exits non-zero instead of a silent 0" \
  "$AUTH_PUSH_STATUS" "255"
check "ssh-auth: \`wip push --all\` says why instead of printing nothing" \
  "$(printf '%s\n' "$AUTH_PUSH_OUT" | grep -c 'not a sleeping hub')" "1"

# 126, not 127: the binary is PRESENT but cannot be executed. That is the
# canonical signature of broken WSL binfmt interop -- ssh.exe is right there on
# home.sessionPath and `command -v` finds it, but exec'ing it yields "Exec
# format error". Guarding 127 alone let this fall through to `return 126`,
# which wip_cmd_push's `wip_hub_up || return 0` turned back into a silent exit
# 0: the same silent timer, reached by a different code. The guard is an
# allow-list of 0/255 precisely so no third code can repeat the trick.
printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/ssh-noexec"
chmod 644 "$SANDBOX/ssh-noexec"
NOEXEC_ERR="$SANDBOX/noexec.err"
( export WIP_SSH="$SANDBOX/ssh-noexec"; wip_hub_up ) 2>"$NOEXEC_ERR"
NOEXEC_STATUS=$?
check "ssh-noexec: a present-but-unexecutable ssh aborts with 126, not a silent 0" \
  "$NOEXEC_STATUS" "126"
check "ssh-noexec: it says so on stderr instead of passing for a sleeping hub" \
  "$(grep -c '^wip: ' "$NOEXEC_ERR")" "2"
check "ssh-noexec: the diagnostic reports the status it actually got" \
  "$(grep -c 'exited 126' "$NOEXEC_ERR")" "1"

# End to end through the dispatcher, run exactly as the generated binary runs it
# (`set -euo pipefail`, both files sourced, argv on the source line) and exactly
# as the timer invokes it. Asserting on wip_hub_up alone would not have caught
# this: the silence came from wip_cmd_push's `wip_hub_up || return 0`.
PUSH_OUT="$(
  ( set -euo pipefail
    export WIP_SSH="definitely-not-a-real-ssh-binary"
    # shellcheck source=/dev/null
    source "$HERE/../home/wip/wip.sh"
    # shellcheck source=/dev/null
    source "$HERE/../home/wip/main.sh" push --all ) 2>&1
)"
PUSH_STATUS=$?
check "ssh-missing: \`wip push --all\` exits non-zero instead of a silent 0" \
  "$PUSH_STATUS" "127"
check "ssh-missing: \`wip push --all\` says why instead of printing nothing" \
  "$(printf '%s\n' "$PUSH_OUT" | grep -c 'no such command on PATH')" "1"
teardown

# --- last successful hub contact ---------------------------------------------
# The belt-and-braces half of the C-1 fix. Classifying ssh's stderr per tick can
# only ever catch failures somebody has already seen; this catches the ones
# nobody has. However wip_hub_up failed, the stamp did not move -- so `wip` can
# say how long it has been rather than leaving the user to infer a problem from
# an absence of output.
setup
# A local-directory hub is never "away", so staleness is meaningless there and
# wip_hub_up never probes; the ssh path is the only one worth asserting on.
# (setup() re-exports WIP_LOCAL_HUB=1, so this does not leak to a later block.)
export WIP_LOCAL_HUB=0
STAMP="$WIP_STATE/last-hub-contact"
printf '#!/usr/bin/env bash\nexit 0\n'   > "$SANDBOX/ssh-ok";     chmod +x "$SANDBOX/ssh-ok"
printf '#!/usr/bin/env bash\nexit 255\n' > "$SANDBOX/ssh-gone";   chmod +x "$SANDBOX/ssh-gone"
export WIP_SSH="$SANDBOX/ssh-ok"

check "stamp: nothing is recorded before the first successful probe" \
  "$([ -e "$STAMP" ] && echo yes || echo no)" "no"
# The first-deploy case, and exactly what artemis would have shown under C-1: a
# timer that has been running for a week and has never once reached the hub.
check "stamp: never having reached the hub is reported, not assumed fine" \
  "$(wip_hub_staleness | grep -c 'NEVER reached the hub')" "1"

wip_hub_up
check "stamp: a successful probe records the contact" \
  "$([ -s "$STAMP" ] && echo yes || echo no)" "yes"
check "stamp: a fresh contact produces no warning at all" "$(wip_hub_staleness)" ""

printf '%s\n' "$(( $(date +%s) - 3 * 86400 ))" > "$STAMP"
check "stamp: an old contact is reported, with its age and the host" \
  "$(wip_hub_staleness | grep -c 'last reached the hub (unused) 3 days ago')" "1"

# Load-bearing: a FAILING probe must not refresh the stamp, or the warning can
# never fire -- which is the whole point of having it.
( export WIP_SSH="$SANDBOX/ssh-gone"; wip_hub_up ) 2>/dev/null
check "stamp: an unreachable hub does not refresh the stamp" \
  "$(wip_hub_staleness | grep -c '3 days ago')" "1"

# And it has to reach the human through the verb they actually type.
check "stamp: bare \`wip\` leads with the stale-hub warning" \
  "$( ( cd "$SANDBOX" && wip_cmd_status ) 2>/dev/null | head -1 | grep -c '3 days ago')" "1"

# A corrupt stamp must read as "never contacted", not as epoch 0 -- a 56-year
# age, i.e. a warning that can never clear and reports something absurd.
printf 'not-a-timestamp\n' > "$STAMP"
check "stamp: a corrupt stamp reads as never-contacted" \
  "$(wip_hub_staleness | grep -c 'NEVER reached the hub')" "1"
unset WIP_SSH
teardown

# --- `wip forget` ------------------------------------------------------------
# Deleting a repo stops its snapshots and drops it from the census, but leaves
# three things with nothing to collect them: the hub's bare repo, this machine's
# shadow cache, and this machine's markers. Measured on the live hub 2026-07-28:
# 23 bare repos, 3 matching no repo on either machine.
#
# The fixture below is that hub in miniature -- four bare repos covering each
# way a slug can be live or not -- so `--list` has something to get wrong in
# both directions. (main.sh was sourced above.)
setup
ORPHAN=github-com-acme-gone-app
THEIRS=github-com-acme-theirs-app
DEMO="$(wip_slug "$REPO")"

# demo2 is live HERE but absent from every census: the case that separates
# "cross-reference the manifests" from "cross-reference reality". Our own
# manifest is only as fresh as the last tick that reached the hub, and
# wip_manifest_write omits any repo whose `git status` failed -- either gap
# would show a repo sitting right here as an orphan, and orphans get deleted.
REPO2="$HOME/work/demo2"
mkdir -p "$REPO2"
git -C "$REPO2" init -q -b main
git -C "$REPO2" config user.email t@t; git -C "$REPO2" config user.name t
git -C "$REPO2" remote add origin https://github.com/acme/Second-App.git
printf 'v1\n' > "$REPO2/tracked.txt"
git -C "$REPO2" add -A; git -C "$REPO2" commit -qm init
DEMO2="$(wip_slug "$REPO2")"

# setup() already made the bare repo for demo; add the other three.
for s in "$ORPHAN" "$THEIRS" "$DEMO2"; do git init --bare -q "$WIP_REMOTE_PATH/$s.git"; done
# ...and the leftovers a deleted repo strands on THIS machine.
git init --bare -q "$WIP_CACHE/$ORPHAN.git"
: > "$WIP_STATE/$ORPHAN.tree"; : > "$WIP_STATE/$ORPHAN.created"

mkdir -p "$WIP_REMOTE_PATH/_manifest"
HEADSHA="$(git -C "$REPO" rev-parse HEAD)"
printf '%s\thttps://github.com/acme/Demo-App.git\twork/demo\t0\t%s\n' \
  "$DEMO" "$HEADSHA" > "$WIP_REMOTE_PATH/_manifest/testhost.tsv"
# The other machine has exactly one repo, at a DIFFERENT path from anything
# here -- that path is what the refusal below has to quote back.
printf '%s\thttps://github.com/acme/Theirs-App.git\tsrc/theirs\t1\t%s\n' \
  "$THEIRS" "$HEADSHA" > "$WIP_REMOTE_PATH/_manifest/otherhost.tsv"

LIST="$( ( cd "$SANDBOX" && wip_cmd_forget --list ) 2>&1 )"
check "forget --list: names the orphaned hub repo" \
  "$(printf '%s\n' "$LIST" | grep -c "^  $ORPHAN\$")" "1"
# Unanchored on purpose. A slug that IS listed gets padded and followed by
# "last seen at ~/...", so a `$`-anchored grep would report 0 for a demo that
# the command had wrongly offered up for deletion -- passing for exactly the
# case it exists to catch. (Mutation-checked: with the live set emptied, the
# anchored form still passed.)
check "forget --list: not a repo that is live here and in our census" \
  "$(printf '%s\n' "$LIST" | grep -c "$DEMO")" "0"
check "forget --list: not a repo that is live only on the other machine" \
  "$(printf '%s\n' "$LIST" | grep -c "$THEIRS")" "0"
# The assertion that fails if the live set is built from the two censuses alone.
check "forget --list: not a repo that is live here but in NO census" \
  "$(printf '%s\n' "$LIST" | grep -c "$DEMO2")" "0"
check "forget --list: counts one orphan out of the four hub repos" \
  "$(printf '%s\n' "$LIST" | grep -c '^1 of 4 hub repo(s) orphaned')" "1"
# `--list` is the read-only half. Nothing it prints may be a side effect.
check "forget --list: leaves every hub repo in place" \
  "$(ls -d "$WIP_REMOTE_PATH"/*.git | wc -l | tr -d ' ')" "4"
check "forget --list: leaves the shadow cache in place" \
  "$([ -d "$WIP_CACHE/$ORPHAN.git" ] && echo yes || echo no)" "yes"
check "forget --list: leaves the markers in place" \
  "$([ -f "$WIP_STATE/$ORPHAN.tree" ] && echo yes || echo no)" "yes"

# --- the refusal: the other machine still has it -----------------------------
# Not a safety warning. Whatever is deleted from the hub, the other machine's
# next tick puts straight back -- so this is "that will not work", and it has to
# be decided BEFORE the prompt, the way wip_cmd_pull decides its gates.
REFUSE_RC=0
REFUSE="$( ( cd "$SANDBOX" && wip_cmd_forget "$THEIRS" <<<y ) 2>&1 )" || REFUSE_RC=$?
check "forget: refuses when the other machine still has the repo" "$REFUSE_RC" "1"
check "forget: the refusal quotes the path the other machine has it at" \
  "$(printf '%s\n' "$REFUSE" | grep -c 'otherhost still has this repo, at ~/src/theirs')" "1"
check "forget: the refusal names --force as the way past it" \
  "$(printf '%s\n' "$REFUSE" | grep -c 'or re-run with --force')" "1"
# Answering `y` above must have been irrelevant: a refusal that still prompts is
# a question whose answer was going to be ignored.
check "forget: a refusal never reaches the prompt" \
  "$(printf '%s\n' "$REFUSE" | grep -c 'Remove them?')" "0"
check "forget: a refusal leaves the hub repo alone" \
  "$([ -d "$WIP_REMOTE_PATH/$THEIRS.git" ] && echo yes || echo no)" "yes"

# --- --force overrides that ---------------------------------------------------
FORCED="$( ( cd "$SANDBOX" && wip_cmd_forget "$THEIRS" --force <<<y ) 2>&1 )"
check "forget --force: still says the other machine has it" \
  "$(printf '%s\n' "$FORCED" | grep -c 'otherhost still has this repo')" "1"
check "forget --force: and goes ahead anyway" \
  "$(printf '%s\n' "$FORCED" | grep -c 'force given')" "1"
check "forget --force: the hub repo really is gone" \
  "$([ -d "$WIP_REMOTE_PATH/$THEIRS.git" ] && echo yes || echo no)" "no"

# --- slug from an argument ----------------------------------------------------
# The common case: the folder is already deleted, so there is nothing to derive
# from but the string. A URL has to normalise to the same slug a repo with that
# origin would have produced -- `wip forget --list` prints slugs, but a user
# reaching for the origin URL must not be told the hub has never heard of it.
PLAN="$( ( cd "$SANDBOX" && wip_cmd_forget https://github.com/acme/Gone-App.git <<<n ) 2>&1 )"
check "forget <url>: normalises a URL argument to the slug" \
  "$(printf '%s\n' "$PLAN" | grep -c "forget \"$ORPHAN\"")" "1"
check "forget: the plan names the hub path it will remove" \
  "$(printf '%s\n' "$PLAN" | grep -c "$WIP_REMOTE_PATH/$ORPHAN.git")" "1"
check "forget: the plan names the shadow cache it will remove" \
  "$(printf '%s\n' "$PLAN" | grep -c "$WIP_CACHE/$ORPHAN.git")" "1"
check "forget: the plan names both markers it will remove" \
  "$(printf '%s\n' "$PLAN" | grep -c "^  marker ")" "2"
# The orphan's bare repo is EMPTY, so there is nothing irrecoverable to warn
# about. The paired assertion, on a hub repo that does hold a snapshot, is in
# the cwd block below.
check "forget: no last-copy warning when the hub repo holds no snapshot" \
  "$(printf '%s\n' "$PLAN" | grep -c 'still holds a snapshot')" "0"
check "forget: answering n removes nothing" \
  "$([ -d "$WIP_REMOTE_PATH/$ORPHAN.git" ] && [ -d "$WIP_CACHE/$ORPHAN.git" ] \
     && [ -f "$WIP_STATE/$ORPHAN.tree" ] && echo intact || echo gone)" "intact"

# A path argument pointing at a LIVE repo must be resolved through its ORIGIN,
# not normalised as a string: `work-demo` is a slug the hub has never held.
PATHARG="$( ( cd "$SANDBOX" && wip_cmd_forget "$REPO" <<<n ) 2>&1 )"
check "forget <path>: a live repo path resolves through its origin, not the path" \
  "$(printf '%s\n' "$PATHARG" | grep -c "forget \"$DEMO\"")" "1"

# ...and a slug nobody has ever heard of is SAID so, not silently acted on.
NOMATCH_RC=0
NOMATCH="$( ( cd "$SANDBOX" && wip_cmd_forget totally-unknown-slug <<<y ) 2>&1 )" || NOMATCH_RC=$?
check "forget: an unmatched slug is an error, not a silent success" "$NOMATCH_RC" "1"
check "forget: ...and it says the hub does not hold it" \
  "$(printf '%s\n' "$NOMATCH" | grep -c 'nothing to forget')" "1"

# --- all three locations, actually cleared ------------------------------------
FORGOT="$( ( cd "$SANDBOX" && wip_cmd_forget "$ORPHAN" <<<y ) 2>&1 )"
check "forget: the hub bare repo is gone" \
  "$([ -e "$WIP_REMOTE_PATH/$ORPHAN.git" ] && echo present || echo gone)" "gone"
check "forget: the shadow cache is gone" \
  "$([ -e "$WIP_CACHE/$ORPHAN.git" ] && echo present || echo gone)" "gone"
check "forget: the .tree marker is gone" \
  "$([ -e "$WIP_STATE/$ORPHAN.tree" ] && echo present || echo gone)" "gone"
check "forget: the .created marker is gone" \
  "$([ -e "$WIP_STATE/$ORPHAN.created" ] && echo present || echo gone)" "gone"
# Scoped: the OTHER slugs' hub repos and this machine's other state survive.
check "forget: it removed only that slug from the hub" \
  "$([ -d "$WIP_REMOTE_PATH/$DEMO.git" ] && [ -d "$WIP_REMOTE_PATH/$DEMO2.git" ] \
     && echo intact || echo damaged)" "intact"
# Point 5: this command cannot reach the other machine, and must say so rather
# than let the user believe the cleanup was complete.
check "forget: says the other machine's cache and markers are NOT cleaned" \
  "$(printf '%s\n' "$FORGOT" | grep -c 'NOT cleaned')" "1"
check "forget: and tells the user to run it there too" \
  "$(printf '%s\n' "$FORGOT" | grep -c "Run \`wip forget $ORPHAN\` there too")" "1"

# --- slug from $PWD, and the hard guarantee -----------------------------------
# No argument, run INSIDE the repo. This is also the one invocation where `wip
# forget` is standing in a working tree while deleting things, so it is where
# the tool's one hard promise is tested: it must never modify the user's repo.
#
# The full .git content manifest, plus a stale index (see stale_index): a `git
# status` anywhere in this path would rewrite .git/index and the manifest would
# catch it, along with any stray ref, lock file or object.
printf 'dirty\n' > "$REPO/tracked.txt"
wip_snapshot "$REPO"          # gives demo a real .tree marker and hub content
wip_fetch "$REPO"             # ...and a real shadow cache
check "forget: the fixture really has all three for the cwd repo" \
  "$([ -d "$WIP_REMOTE_PATH/$DEMO.git" ] && [ -d "$WIP_CACHE/$DEMO.git" ] \
     && [ -f "$WIP_STATE/$DEMO.tree" ] && echo yes || echo no)" "yes"

stale_index "$REPO"
BEFORE_GIT="$(git_manifest "$REPO")"
BEFORE_TRACKED="$(cat "$REPO/tracked.txt")"
CWD_OUT="$( ( cd "$REPO" && wip_cmd_forget <<<y ) 2>&1 )"

check "forget: derives the slug from the repo in \$PWD, via its origin" \
  "$(printf '%s\n' "$CWD_OUT" | grep -c "forget \"$DEMO\"")" "1"
# Once both machines have deleted a repo, the hub's bare repo is the ONLY copy
# of its uncommitted work -- nothing was committed, and `wip undo` cannot reach
# it. Measured on the live hub 2026-07-28: all three of its orphans still held a
# 4-hour-old snapshot, so this is the ordinary case for an orphan.
check "forget: warns that the hub repo still holds an unrecoverable snapshot" \
  "$(printf '%s\n' "$CWD_OUT" | grep -c 'it still holds a snapshot from testhost')" "1"
# Run from inside a repo that is still here, the tick will just recreate it --
# a note rather than a refusal, because this form exists for the moment before
# you delete the repo.
check "forget: warns that a repo still present here will be recreated" \
  "$(printf '%s\n' "$CWD_OUT" | grep -c 'still exists here, at ~/work/demo')" "1"
check "forget: from \$PWD, all three locations are cleared" \
  "$([ -e "$WIP_REMOTE_PATH/$DEMO.git" ] || [ -e "$WIP_CACHE/$DEMO.git" ] \
     || [ -e "$WIP_STATE/$DEMO.tree" ] || [ -e "$WIP_STATE/$DEMO.created" ] \
     && echo leftover || echo clean)" "clean"
# THE hard guarantee. Byte-for-byte over every file in .git.
check "forget: the user's repo is not modified at all" \
  "$(git_manifest "$REPO")" "$BEFORE_GIT"
check "forget: the working tree is left alone" \
  "$(cat "$REPO/tracked.txt")" "$BEFORE_TRACKED"
check "forget: the repo itself still exists" \
  "$([ -d "$REPO/.git" ] && echo yes || echo no)" "yes"
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
