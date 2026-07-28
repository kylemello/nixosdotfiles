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
printf 'dirty\n' > "$REPO/tracked.txt"
wip_manifest_write
MAN="$WIP_REMOTE_PATH/_manifest/testhost.tsv"
check "manifest: written" "$([ -f "$MAN" ] && echo yes || echo no)" "yes"
check "manifest: one line per repo" "$(wc -l < "$MAN" | tr -d ' ')" "1"
check "manifest: records origin" \
  "$(cut -f2 "$MAN")" "https://github.com/acme/Demo-App.git"
check "manifest: records rel path" "$(cut -f3 "$MAN")" "work/demo"
check "manifest: marks dirty" "$(cut -f4 "$MAN")" "1"
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
