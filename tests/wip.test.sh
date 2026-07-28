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
BEFORE_STATUS="$(git -C "$REPO" status --porcelain)"
BEFORE_INDEX="$(cksum < "$REPO/.git/index")"

wip_snapshot "$REPO"

check "repo untouched: remotes"   "$(git -C "$REPO" remote -v)"        "$BEFORE_REMOTES"
check "repo untouched: branches"  "$(git -C "$REPO" branch -a)"        "$BEFORE_BRANCHES"
check "repo untouched: all refs"  "$(git -C "$REPO" for-each-ref)"     "$BEFORE_ALLREFS"
check "repo untouched: HEAD"      "$(git -C "$REPO" rev-parse HEAD)"   "$BEFORE_HEAD"
check "repo untouched: status"    "$(git -C "$REPO" status --porcelain)" "$BEFORE_STATUS"
check "repo untouched: index"     "$(cksum < "$REPO/.git/index")"     "$BEFORE_INDEX"

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
  "$(git --git-dir="$SHADOW" rev-parse --verify --quiet refs/wip/pre-pull >/dev/null && echo yes || echo no)" \
  "yes"
# The ref must capture the live WORKING TREE, not HEAD. Asserted against the
# ref's TREE rather than a file on disk on purpose: `git checkout <tree-ish> -- .`
# never DELETES paths that are absent from the tree-ish (verified), so a file
# that exists only locally is never at risk, and checking that it is still there
# after a restore would prove nothing.
check "safety: ref captures untracked work" \
  "$(git --git-dir="$SHADOW" ls-tree -r --name-only refs/wip/pre-pull | grep -c '^scratch\.txt$')" "1"
check "safety: ref honours .gitignore" \
  "$(git --git-dir="$SHADOW" ls-tree -r --name-only refs/wip/pre-pull | grep -c node_modules)" "0"
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
  "$(git --git-dir="$SHADOW" ls-tree -r refs/wip/pre-pull | awk '{print $3}' \
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

git --git-dir="$SHADOW" --work-tree="$REPO" checkout refs/wip/pre-pull -- .
check "safety: undo restores the tracked file"   "$(cat "$REPO/tracked.txt")" "my-local-work"
check "safety: undo restores the untracked file" "$(cat "$REPO/scratch.txt")" "my-scratch"
check "safety: real repo still has no refs of its own" \
  "$(git -C "$REPO" for-each-ref --format='%(refname)' | grep -c '^refs/wip/')" "0"
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
