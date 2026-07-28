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
#   WIP_SSH          the ssh command to reach the hub; defaults to plain `ssh`
#
# EVERY ssh invocation below goes through "${WIP_SSH:-ssh}", never bare `ssh`.
# artemis is WSL and its 1Password SSH agent lives on the Windows side, which is
# why home/wsl.nix sets git's core.sshCommand to `ssh.exe`. GIT_SSH_COMMAND
# covers git's own push/fetch, but nothing covers a direct `ssh` call -- those
# would reach for an agent that is not there and fail authentication. The
# `:-ssh` default is what keeps the test suite and non-WSL hosts unaffected.

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
  local ssh="${WIP_SSH:-ssh}" status=0
  # `|| status=$?` rather than a bare call plus `$?`: this must read the same
  # under `set -e` no matter how the caller invoked us.
  "$ssh" -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
      "$WIP_REMOTE_HOST" true 2>/dev/null || status=$?

  # A sleeping hub and a broken local ssh MUST NOT look alike.
  #
  # The probe above sends its stderr to /dev/null, because a LAN-only hub being
  # away is the normal case and must stay quiet. That redirection also swallows
  # the SHELL's own "command not found", so a misconfigured WIP_SSH used to
  # arrive here as a plain non-zero and be reported as "hub away" -- measured:
  # `wip push --all` exited 0 with no output at all, so the timer would push
  # nothing and log nothing, every 5 minutes, forever. It survives manual
  # testing too: `ssh.exe` resolves in an interactive fish (home.sessionPath)
  # but not in a systemd user unit, which is where the timer runs.
  #
  # The test is an ALLOW-LIST, deliberately, not a list of bad statuses. The
  # probe runs `true`, so the only two statuses a healthy setup can produce are
  # 0 (hub answered) and 255 (OpenSSH's reserved code for its own failures:
  # cannot resolve, cannot connect, connection refused -- i.e. the hub is away).
  # Everything else came from this end. Enumerating the bad codes gets it the
  # wrong way round: any code left off the list falls through to
  # `return "$status"`, and main.sh's `wip_hub_up || return 0` launders that
  # straight back into a silent exit 0. That is how 126 -- the status for a
  # binary that EXISTS but cannot be executed, which is exactly what broken WSL
  # binfmt interop does to ssh.exe ("Exec format error") -- would have walked
  # back in through a different door after 127 was closed.
  case "$status" in
    0|255) return "$status" ;;
  esac

  # 127 is the shell's command-not-found status, but ssh also exits 127 when the
  # REMOTE command does, so confirm with `command -v` before blaming the config.
  if [ "$status" -eq 127 ] && ! command -v "$ssh" >/dev/null 2>&1; then
    printf 'wip: WIP_SSH=%s: no such command on PATH\n' "$ssh" >&2
  else
    printf 'wip: WIP_SSH=%s: probing %s exited %s (expected 0, or 255 if the hub is away)\n' \
      "$ssh" "$WIP_REMOTE_HOST" "$status" >&2
  fi
  printf 'wip: that is a misconfiguration, not a sleeping hub — aborting.\n' >&2
  # `exit`, not `return`: every caller treats a non-zero wip_hub_up as "hub
  # away, retry next tick" and deliberately swallows it, so a return value
  # would be laundered straight back into the silence this exists to prevent.
  # No operation in this run can succeed without a working ssh.
  exit "$status"
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
    "${WIP_SSH:-ssh}" "$WIP_REMOTE_HOST" "git init --bare -q '$WIP_REMOTE_PATH/$slug.git' 2>/dev/null || true"
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

# The other machine. There are exactly two, so this is unambiguous.
wip_other_host() {
  case "$WIP_HOST" in
    artemis) printf 'ariane'  ;;
    ariane)  printf 'artemis' ;;
    *)       printf 'otherhost' ;;   # tests
  esac
}

wip_shadow() { printf '%s/%s.git' "$WIP_CACHE" "$1"; }

wip_manifest_path() { printf '%s/_manifest/%s.tsv' "$WIP_REMOTE_PATH" "$1"; }

# Publish this machine's repo census: every repo, dirty or not. `wip clone`
# reads the other host's census to find repos missing here.
#
# Matches wip_snapshot's failure discipline: gateway is only reachable from
# the home LAN or over UniFi Teleport, so an unreachable hub is the NORMAL
# case, not an exception, and must be surfaced rather than swallowed -- a
# manifest write that silently "succeeds" while publishing nothing would
# leave the hub's copy of this host's census stale without any signal, and
# `wip clone` trusts that census as ground truth for what exists here.
wip_manifest_write() {
  local repo slug url rel dirty head out remote_dest remote_tmp
  if ! out="$(mktemp "${TMPDIR:-/tmp}/wip-man.XXXXXX")"; then
    printf 'wip: manifest: mktemp failed, not publishing\n' >&2
    return 1
  fi
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    head="$(git -C "$repo" rev-parse --verify --quiet HEAD)" || continue
    slug="$(wip_slug "$repo")"
    url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
    rel="${repo#"$HOME"/}"
    if [ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then dirty=0; else dirty=1; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$url" "$rel" "$dirty" "$head" >> "$out"
  done < <(wip_repos)

  if wip_local_hub; then
    if ! mkdir -p "$WIP_REMOTE_PATH/_manifest" || ! mv "$out" "$(wip_manifest_path "$WIP_HOST")"; then
      printf 'wip: manifest: failed to write local hub manifest\n' >&2
      rm -f "$out"
      return 1
    fi
  else
    # Two SEPARATE ssh calls, not one command chained with `&&` on the
    # remote side. A dropped connection can leave the remote shell having
    # received only part of $out -- but whether the remote side treats that
    # as a clean EOF or gets killed outright, the LOCAL ssh client here
    # (which is still trying to send the rest of $out into a dead channel)
    # reliably reports non-zero either way. Gating the `mv` on THAT exit
    # status, in our own code rather than a remote `&&`, means a failed
    # transfer can never reach the rename step: it lands in a discardable
    # remote_tmp, never in remote_dest, so the previous good manifest
    # survives untouched. (Regression: streaming straight into remote_dest
    # via `cat > remote_dest` left the hub holding a truncated census after
    # exactly this kind of failure.)
    remote_dest="$(wip_manifest_path "$WIP_HOST")"
    remote_tmp="$remote_dest.$$.tmp"
    if ! "${WIP_SSH:-ssh}" "$WIP_REMOTE_HOST" \
        "mkdir -p '$WIP_REMOTE_PATH/_manifest' && cat > '$remote_tmp'" < "$out"; then
      printf 'wip: manifest: hub unreachable, not published\n' >&2
      rm -f "$out"
      "${WIP_SSH:-ssh}" "$WIP_REMOTE_HOST" "rm -f '$remote_tmp'" 2>/dev/null || true
      return 1
    fi
    rm -f "$out"
    if ! "${WIP_SSH:-ssh}" "$WIP_REMOTE_HOST" "mv '$remote_tmp' '$remote_dest'"; then
      printf 'wip: manifest: hub unreachable, not published\n' >&2
      "${WIP_SSH:-ssh}" "$WIP_REMOTE_HOST" "rm -f '$remote_tmp'" 2>/dev/null || true
      return 1
    fi
  fi
}

# Read another host's manifest. A missing file just means that host hasn't
# published a census yet (e.g. first run) -- not an error worth failing on --
# so this still returns success with empty output in that case.
wip_manifest_read() {
  local host="$1"
  if wip_local_hub; then
    cat "$(wip_manifest_path "$host")" 2>/dev/null || true
  else
    "${WIP_SSH:-ssh}" "$WIP_REMOTE_HOST" "cat '$(wip_manifest_path "$host")' 2>/dev/null" || true
  fi
}

# Pull the other host's snapshot into a shadow repo under $WIP_CACHE. The real
# repo is never opened for writing, so it gains no refs and no objects.
#
# Same discipline as wip_snapshot: an unreachable hub (the normal case off
# the home LAN) or a shadow repo that can't be created/fetched into must be
# reported non-zero with a diagnostic, not swallowed as success -- a caller
# that trusts a silent "ok" here would tell the user their WIP is current
# when nothing was actually fetched.
wip_fetch() {
  local repo="$1" slug shadow target
  slug="$(wip_slug "$repo")"
  shadow="$(wip_shadow "$slug")"
  target="$(wip_push_target "$slug")"

  if [ ! -d "$shadow" ]; then
    if ! mkdir -p "$WIP_CACHE"; then
      printf 'wip: %s: mkdir failed, cannot create shadow cache\n' "$repo" >&2
      return 1
    fi
    if ! git init --bare -q "$shadow"; then
      printf 'wip: %s: git init --bare failed for shadow repo\n' "$repo" >&2
      return 1
    fi
  fi
  if ! git --git-dir="$shadow" fetch --quiet --prune --force \
      "$target" 'refs/heads/wip/*:refs/wip/*' 2>/dev/null; then
    printf 'wip: %s: fetch from hub failed, will retry next run\n' "$repo" >&2
    return 1
  fi
}

# Diff a shadow snapshot ref against the real working tree.
#
# The shadow is bare and only ever fetched into, so its index is EMPTY, and
# `git diff <ref>` consults the index to decide what is tracked. With an empty
# index every path in the snapshot reports as deleted -- measured: an identical
# snapshot and worktree produced "1 file changed, 1 deletion(-)". read-tree the
# ref into the shadow's index first so the comparison is against reality.
#
# Every diff of a shadow ref must go through this. Calling `git diff` directly
# on a shadow git-dir is the bug this function exists to prevent.
wip_shadow_diff() {
  local repo="$1" ref="$2"; shift 2
  local shadow; shadow="$(wip_shadow "$(wip_slug "$repo")")"
  git --git-dir="$shadow" read-tree "$ref" 2>/dev/null || {
    printf 'wip: %s: no snapshot ref %s in the shadow cache\n' "$repo" "$ref" >&2
    return 1
  }
  git --git-dir="$shadow" --work-tree="$repo" diff "$ref" "$@"
}

# The repo containing $PWD, or empty if we are not in one.
wip_cwd_repo() { git rev-parse --show-toplevel 2>/dev/null || true; }

# Age of the other host's snapshot for a repo, in seconds. Empty if none.
wip_snapshot_age() {
  local shadow="$1" ref="refs/wip/$(wip_other_host)" ts
  ts="$(git --git-dir="$shadow" log -1 --format=%ct "$ref" 2>/dev/null)" || return 0
  [ -n "$ts" ] || return 0
  printf '%s' "$(( $(date +%s) - ts ))"
}

wip_human_age() {
  local s="$1"
  if   [ "$s" -lt 90 ];    then printf '%d sec' "$s"
  elif [ "$s" -lt 5400 ];  then printf '%d min' "$(( s / 60 ))"
  elif [ "$s" -lt 172800 ];then printf '%d hr'  "$(( s / 3600 ))"
  else                          printf '%d days' "$(( s / 86400 ))"; fi
}

# One-line summary for the current repo, or empty. Used by both `wip` and the
# fish cd-hook, so they can never disagree.
wip_notice() {
  local repo="$1" slug shadow age stat
  slug="$(wip_slug "$repo")"; shadow="$(wip_shadow "$slug")"
  [ -d "$shadow" ] || return 0
  age="$(wip_snapshot_age "$shadow")"
  [ -n "$age" ] || return 0
  stat="$(wip_shadow_diff "$repo" "refs/wip/$(wip_other_host)" --shortstat 2>/dev/null)"
  [ -n "$stat" ] || return 0
  printf '⬇  snapshot from %s · %s ago ·%s · run `wip pull`\n' \
    "$(wip_other_host)" "$(wip_human_age "$age")" "$stat"
}
