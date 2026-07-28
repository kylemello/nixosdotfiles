# wip — cross-machine working-tree snapshots.
#
# Sourced by the generated `wip` binary (home/wip.nix) and by the test suite.
# Defines functions only; no top-level side effects.
#
# Environment contract (all set by home/wip.nix, overridden by tests):
#   WIP_HOST         this machine's logical name ("artemis" / "ariane")
#   WIP_REMOTE_HOST  ssh host of the hub ("gateway")
#   WIP_REMOTE_PATH  absolute path on the hub ("/home/kyle/wip")
#   WIP_ROOTS        space-separated roots under $HOME ("personal work")
#   WIP_CACHE        shadow repos live here
#   WIP_STATE        per-repo markers live here

# Normalize a repo to a stable slug. Derived from `origin` rather than the
# directory name, because the same project has different directory names on
# each machine (DocResolve-brrit-com vs DocResolve-brrit.com). Falls back to
# the $HOME-relative path for repos with no origin.
wip_slug() {
  local repo="$1" url
  url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  if [ -n "$url" ]; then
    printf '%s' "$url" \
      | sed -E 's#^[a-z+]+://##; s#^[^@/]+@##; s#:#/#; s#\.git$##' \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's#[^a-z0-9]+#-#g; s#^-+##; s#-+$##'
  else
    printf '%s' "${repo#"$HOME"/}" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's#[^a-z0-9]+#-#g; s#^-+##; s#-+$##'
  fi
}

# Print the absolute path of every git repo under the configured roots.
# `find` does not follow symlinks without -L, so artemis's
# ~/work/work-knowledge-repo -> /mnt/c/... vault is skipped automatically.
wip_repos() {
  local root
  for root in $WIP_ROOTS; do
    [ -d "$HOME/$root" ] || continue
    find "$HOME/$root" -maxdepth 3 -type d -name .git -prune -print 2>/dev/null \
      | while IFS= read -r g; do dirname "$g"; done
  done
}

wip_url()  { printf 'ssh://%s%s/%s.git' "$WIP_REMOTE_HOST" "$WIP_REMOTE_PATH" "$1"; }

# Is the hub a local directory (tests) or a real ssh host (production)?
#
# This MUST be an explicit flag, never `[ -d "$WIP_REMOTE_PATH" ]`. artemis's
# $HOME is /home/kyle and WIP_REMOTE_PATH is /home/kyle/wip, so a directory
# test would silently make artemis push snapshots to itself instead of
# gateway — and nothing would ever surface the mistake.
wip_local_hub() { [ "${WIP_LOCAL_HUB:-0}" = "1" ]; }

# Is the hub reachable right now? gateway is LAN-only — no tailnet node
# advertises 10.11.12.0/24 (verified 2026-07-28), so ariane can only reach it on
# the home network or over UniFi Teleport. An unreachable hub is therefore the
# NORMAL case, not an error, and must be cheap to detect: without this probe,
# 22 repos x SSH's ~75s TCP default would hang the timer for ~27 minutes and
# overlapping runs would pile up.
wip_hub_up() {
  wip_local_hub && return 0
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
      "$WIP_REMOTE_HOST" true 2>/dev/null
}

wip_push_target() {
  if wip_local_hub; then printf '%s/%s.git' "$WIP_REMOTE_PATH" "$1"
  else wip_url "$1"; fi
}

# Create the bare repo on the hub the first time we push to it. Marker file
# avoids an ssh round-trip on every tick thereafter.
wip_ensure_bare() {
  local slug="$1" flag="$WIP_STATE/$1.created"
  [ -f "$flag" ] && return 0
  if wip_local_hub; then
    git init --bare -q "$WIP_REMOTE_PATH/$slug.git" 2>/dev/null || true
  else
    ssh "$WIP_REMOTE_HOST" "git init --bare -q '$WIP_REMOTE_PATH/$slug.git' 2>/dev/null || true"
  fi
  mkdir -p "$WIP_STATE"; : > "$flag"
}

# Snapshot one repo's working tree to the hub.
#
# Builds the tree through a TEMPORARY index so the real .git/index is never
# written, and commits it PARENTLESS so no history is transferred and the
# shadow cache stays tiny. The base commit and branch go in the message
# instead. Pushes by URL so .git/config is never modified.
#
# Every step between building the temp index and computing its tree is
# checked explicitly. `GIT_INDEX_FILE=<unusable-path> git write-tree` does
# NOT itself fail the way `read-tree`/`add -A` do -- it can silently return
# git's canonical empty-tree hash. Left unchecked (as this function used to
# be), a broken mktemp/read-tree/add step looks identical to "the repo really
# is empty" and force-pushes an empty tree over a good snapshot -- or worse:
# an empty $tree from a swallowed failure turns "$sha:refs/heads/wip/$WIP_HOST"
# into a delete refspec, erasing the hub snapshot outright. On any failure
# below we bail out non-zero, without touching the marker (so the next tick
# retries) and without pushing (so the hub keeps whatever snapshot it had).
wip_snapshot() {
  local repo="$1" head slug idx tree branch sha target marker empty_tree
  head="$(git -C "$repo" rev-parse --verify --quiet HEAD)" || return 0
  slug="$(wip_slug "$repo")"
  target="$(wip_push_target "$slug")"
  marker="$WIP_STATE/$slug.tree"
  mkdir -p "$WIP_STATE"

  if ! idx="$(mktemp "${TMPDIR:-/tmp}/wip-idx.XXXXXX")"; then
    printf 'wip: %s: mktemp failed, skipping snapshot\n' "$repo" >&2
    return 1
  fi
  if ! GIT_INDEX_FILE="$idx" git -C "$repo" read-tree "$head"; then
    printf 'wip: %s: read-tree failed, skipping snapshot\n' "$repo" >&2
    rm -f "$idx"
    return 1
  fi
  if ! GIT_INDEX_FILE="$idx" git -C "$repo" add -A; then
    printf 'wip: %s: add -A failed, skipping snapshot\n' "$repo" >&2
    rm -f "$idx"
    return 1
  fi
  if ! tree="$(GIT_INDEX_FILE="$idx" git -C "$repo" write-tree)"; then
    printf 'wip: %s: write-tree failed, skipping snapshot\n' "$repo" >&2
    rm -f "$idx"
    return 1
  fi
  rm -f "$idx"

  # Belt-and-braces: an empty tree is only a legitimate result for a
  # genuinely empty repo. If write-tree produced one anyway while the
  # working tree actually has tracked or untracked, non-ignored files,
  # refuse to push -- this is what keeps the bug above fixed even if a
  # future change to the steps above reintroduces a silent failure.
  empty_tree="$(git -C "$repo" hash-object -t tree /dev/null)"
  if [ "$tree" = "$empty_tree" ] && [ -n "$(git -C "$repo" ls-files -co --exclude-standard)" ]; then
    printf 'wip: %s: computed tree is unexpectedly empty, refusing to push\n' "$repo" >&2
    return 1
  fi

  # Clean tree: nothing uncommitted to carry. Drop any stale snapshot so the
  # other machine stops being told there is work waiting.
  if [ "$tree" = "$(git -C "$repo" rev-parse "$head^{tree}")" ]; then
    if [ -f "$marker" ]; then
      git -C "$repo" push --quiet "$target" ":refs/heads/wip/$WIP_HOST" 2>/dev/null || true
      rm -f "$marker"
    fi
    return 0
  fi

  # Unchanged since the last push: skip the network entirely.
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$tree" ]; then return 0; fi

  branch="$(git -C "$repo" branch --show-current)"
  if ! sha="$(git -C "$repo" commit-tree "$tree" -m \
    "wip@$WIP_HOST $(date -Iseconds) base=$(git -C "$repo" rev-parse --short "$head") branch=${branch:-DETACHED}")"; then
    printf 'wip: %s: commit-tree failed, skipping snapshot\n' "$repo" >&2
    return 1
  fi

  wip_ensure_bare "$slug"
  if ! git -C "$repo" push --force --quiet "$target" "$sha:refs/heads/wip/$WIP_HOST"; then
    printf 'wip: %s: push to hub failed, will retry next run\n' "$repo" >&2
    return 1
  fi
  printf '%s' "$tree" > "$marker"
}
