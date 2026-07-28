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
wip_snapshot "$REPO"
check "snapshot: unchanged tree is not re-pushed" \
  "$(git -C "$BARE" rev-parse refs/heads/wip/testhost)" "$SNAP"

git -C "$REPO" checkout -q -- tracked.txt
rm -f "$REPO/untracked.txt"
wip_snapshot "$REPO"
check "snapshot: clean tree deletes the stale snapshot" \
  "$(git -C "$BARE" rev-parse --verify --quiet refs/heads/wip/testhost || echo gone)" "gone"
teardown

# --- discovery ---------------------------------------------------------------
setup
mkdir -p "$HOME/work/plain"                       # not a repo
ln -s /nonexistent "$HOME/work/dangling-link"     # symlink, must be skipped
check "discovery: finds repos, skips non-repos and symlinks" \
  "$(wip_repos | wc -l | tr -d ' ')" "1"
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
