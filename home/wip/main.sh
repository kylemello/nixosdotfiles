# Entry point for the `wip` command. Sourced after wip.sh by the generated
# binary (home/wip.nix).

wip_cmd_push() {
  local repo
  if [ "${1:-}" = "--all" ]; then
    # Silent no-op when the hub is away — this runs every 5 minutes and being
    # off-LAN is expected, not worth a log line.
    wip_hub_up || return 0
    # `|| true` per repo: one repo in a strange state must not abort the rest,
    # and must not skip wip_manifest_write below. The tree marker is only
    # written on a successful push, so a failure simply retries next tick.
    while IFS= read -r repo; do
      [ -n "$repo" ] && { wip_snapshot "$repo" || true; }
    done < <(wip_repos)
    wip_manifest_write || true
  else
    repo="$(wip_cwd_repo)"
    [ -n "$repo" ] || { echo "wip: not in a git repo" >&2; return 1; }
    wip_hub_up || { echo "wip: hub ($WIP_REMOTE_HOST) unreachable — will retry on the next tick"; return 0; }
    wip_snapshot "$repo"
  fi
}

wip_cmd_fetch_all() {
  local repo
  wip_hub_up || return 0
  while IFS= read -r repo; do
    [ -n "$repo" ] && { wip_fetch "$repo" || true; }
  done < <(wip_repos)
}

wip_cmd_diff() {
  local repo slug shadow
  repo="$(wip_cwd_repo)"
  [ -n "$repo" ] || { echo "wip: not in a git repo" >&2; return 1; }
  slug="$(wip_slug "$repo")"; shadow="$(wip_shadow "$slug")"
  [ -d "$shadow" ] || { echo "wip: no snapshot for this repo"; return 0; }
  wip_shadow_diff "$repo" "refs/wip/$(wip_other_host)"
}

# Capture the CURRENT working tree into the shadow repo before anything
# overwrites it. `wip pull` is the only operation in this system that writes to
# a working tree, so it is the only one that can lose work — this makes it
# reversible via `wip undo`.
#
# Everything is written through the SHADOW's git-dir with the real repo as
# --work-tree, so the objects land in the cache and the real repo is only ever
# read. .gitignore still applies, because `add -A` reads the ignore files out
# of the work tree.
# Every step is guarded and the function returns non-zero on any failure. This
# is the guard on a destructive operation: if it silently half-worked, `wip pull`
# would overwrite the working tree and then claim the previous state was saved.
# Its caller MUST refuse to proceed when this returns non-zero.
wip_safety_ref() {
  local repo="$1" shadow="$2" idx tree sha
  idx="$(mktemp "${TMPDIR:-/tmp}/wip-safe.XXXXXX")" || {
    printf 'wip: %s: mktemp failed, refusing to pull without a safety ref\n' "$repo" >&2
    return 1; }
  # mktemp leaves a ZERO-BYTE file behind, and git DIES on a zero-byte index:
  # "fatal: <path>: index file smaller than expected", exit 128 -- measured on
  # git 2.54.0. A *missing* index path is what git reads as "empty index", so
  # remove the file we just reserved. Without this the safety ref could never be
  # written and `wip pull` would refuse every single time.
  #
  # The index must start EMPTY (rather than seeded from HEAD the way
  # wip_snapshot seeds its temp index, which is how wip_snapshot dodges the same
  # trap): with an empty index every worktree file counts as new, so `add -A`
  # writes every blob into the SHADOW's object store. Seeding from the real
  # repo's HEAD would build a tree referencing objects only the real repo has,
  # and `wip undo` would then fail on missing blobs.
  rm -f "$idx"
  if ! GIT_INDEX_FILE="$idx" git --git-dir="$shadow" --work-tree="$repo" add -A; then
    rm -f "$idx"
    printf 'wip: %s: could not stage the current tree for the safety ref\n' "$repo" >&2
    return 1
  fi
  if ! tree="$(GIT_INDEX_FILE="$idx" git --git-dir="$shadow" write-tree)" || [ -z "$tree" ]; then
    rm -f "$idx"
    printf 'wip: %s: write-tree failed for the safety ref\n' "$repo" >&2
    return 1
  fi
  rm -f "$idx"
  if ! sha="$(git --git-dir="$shadow" commit-tree "$tree" \
              -m "pre-pull@$WIP_HOST $(date -Iseconds)")" || [ -z "$sha" ]; then
    printf 'wip: %s: commit-tree failed for the safety ref\n' "$repo" >&2
    return 1
  fi
  if ! git --git-dir="$shadow" update-ref refs/wip/pre-pull "$sha"; then
    printf 'wip: %s: could not write refs/wip/pre-pull\n' "$repo" >&2
    return 1
  fi
}

# Deliberate by design: never overwrite a working tree without consent.
wip_cmd_pull() {
  local repo slug shadow force="${1:-}" reply porcelain
  repo="$(wip_cwd_repo)"
  [ -n "$repo" ] || { echo "wip: not in a git repo" >&2; return 1; }
  slug="$(wip_slug "$repo")"; shadow="$(wip_shadow "$slug")"
  git --git-dir="$shadow" rev-parse --verify --quiet "refs/wip/$(wip_other_host)" >/dev/null 2>&1 \
    || { echo "wip: no snapshot from $(wip_other_host) for this repo"; return 0; }

  # `--no-optional-locks`, same as wip_manifest_write and for the same reason: a
  # plain `git status` rewrites .git/index when the stat cache is stale, and
  # this tool must never write to the user's repo outside the deliberate
  # checkout below. The exit status is checked too -- an empty stdout from a
  # FAILED status reads as "clean tree", and this is the gate standing in front
  # of the one operation here that can destroy uncommitted work.
  if ! porcelain="$(git --no-optional-locks -C "$repo" status --porcelain)"; then
    echo "wip: cannot tell whether your working tree is clean (git status failed)." >&2
    echo "     Refusing to overwrite it. Re-run with --force if you are sure." >&2
    [ "$force" = "--force" ] || return 1
  fi
  if [ -n "$porcelain" ] && [ "$force" != "--force" ]; then
    echo "wip: your working tree has changes."
    echo "     Review with \`wip diff\`, then re-run with --force to overwrite."
    return 1
  fi

  wip_shadow_diff "$repo" "refs/wip/$(wip_other_host)" --stat
  printf 'Apply this snapshot over %s? [y/N] ' "$repo"
  read -r reply
  case "$reply" in
    y|Y) # Refuse to overwrite the working tree if the safety ref did not land.
         # Without this gate a failed safety ref still lets the checkout run, and
         # the success message below would be a lie at the one moment it matters.
         if ! wip_safety_ref "$repo" "$shadow"; then
           echo "wip: aborted — could not save your current tree first." >&2
           return 1
         fi
         # `:/` and not `.`: a pathspec of `.` resolves against the CWD, so a pull
         # from a subdirectory applied only that subtree (measured) while the diff
         # shown above the prompt, and the "applied" below, described the whole
         # tree. `:/` always means the top of the work tree, whatever the CWD.
         git --git-dir="$shadow" --work-tree="$repo" checkout "refs/wip/$(wip_other_host)" -- :/ \
           || { echo "wip: checkout failed; your tree is saved at refs/wip/pre-pull (\`wip undo\`)." >&2; return 1; }
         echo "wip: applied. Previous tree saved — \`wip undo\` restores it." ;;
    *)   echo "wip: aborted." ;;
  esac
}

# Restore the tree as it was immediately before the last `wip pull`.
wip_cmd_undo() {
  local repo slug shadow reply
  repo="$(wip_cwd_repo)"
  [ -n "$repo" ] || { echo "wip: not in a git repo" >&2; return 1; }
  slug="$(wip_slug "$repo")"; shadow="$(wip_shadow "$slug")"
  git --git-dir="$shadow" rev-parse --verify --quiet refs/wip/pre-pull >/dev/null 2>&1 \
    || { echo "wip: no pre-pull snapshot for this repo"; return 0; }

  echo "Restoring the tree from $(git --git-dir="$shadow" log -1 --format=%s refs/wip/pre-pull):"
  wip_shadow_diff "$repo" refs/wip/pre-pull --stat
  printf 'Restore? [y/N] '
  read -r reply
  case "$reply" in
    y|Y) # `:/`, not `.` -- same reason as wip_cmd_pull: restore the whole tree
         # regardless of which subdirectory this was run from.
         git --git-dir="$shadow" --work-tree="$repo" checkout refs/wip/pre-pull -- :/
         echo "wip: restored." ;;
    *)   echo "wip: aborted." ;;
  esac
}

# Repos that exist on the other machine but not here.
wip_missing() {
  local other slug url rel dirty head
  other="$(wip_other_host)"
  while IFS=$'\t' read -r slug url rel dirty head; do
    [ -n "$slug" ] || continue
    [ -n "$url" ]  || continue          # no origin: nothing to clone from
    [ -e "$HOME/$rel" ] && continue
    printf '%s\t%s\t%s\n' "$slug" "$url" "$rel"
  done < <(wip_manifest_read "$other")
}

wip_cmd_clone() {
  local slug url rel n=0 reply
  while IFS=$'\t' read -r slug url rel; do
    [ -n "$rel" ] || continue
    printf '  %s  ->  ~/%s\n' "$url" "$rel"; n=$((n+1))
  done < <(wip_missing)
  [ "$n" -gt 0 ] || { echo "wip: nothing to clone."; return 0; }
  printf 'Clone %d repo(s)? [y/N] ' "$n"; read -r reply
  case "$reply" in y|Y) ;; *) echo "wip: aborted."; return 0 ;; esac
  while IFS=$'\t' read -r slug url rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$(dirname "$HOME/$rel")"
    git clone "$url" "$HOME/$rel" || echo "wip: failed to clone $url" >&2
  done < <(wip_missing)
}

# Bare `wip`: in a repo, report on it. Elsewhere, report on everything.
wip_cmd_status() {
  local repo n=0 notice slug url rel stale
  # First line, and in BOTH branches below, because "why has nothing happened?"
  # is asked from inside a repo at least as often as outside one. This is the
  # half of the C-1 fix that does not depend on classifying ssh's stderr
  # correctly: however wip_hub_up failed, the stamp did not move, and the user
  # gets "last reached the hub 3 days ago" instead of an unexplained silence.
  stale="$(wip_hub_staleness)"
  if [ -n "$stale" ]; then printf '%s\n' "$stale"; fi
  repo="$(wip_cwd_repo)"
  if [ -n "$repo" ]; then
    notice="$(wip_notice "$repo")"
    # `\n` and not bare '%s': wip_notice ends its line with a newline, but the
    # command substitution above strips it, so the newline has to be put back
    # here or the next shell prompt lands on the end of the notice.
    if [ -n "$notice" ]; then printf '%s\n' "$notice"
    else echo "wip: nothing waiting for this repo."; fi
    return 0
  fi

  echo "Snapshots waiting from $(wip_other_host):"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    notice="$(wip_notice "$repo")"
    [ -n "$notice" ] || continue
    printf '  %-40s %s\n' "${repo#"$HOME"/}" "$notice"; n=$((n+1))
  done < <(wip_repos)
  [ "$n" -gt 0 ] || echo "  (none)"

  n=0
  while IFS=$'\t' read -r slug url rel; do [ -n "$rel" ] && n=$((n+1)); done < <(wip_missing)
  if [ "$n" -gt 0 ]; then
    printf '\n%s has %d repo(s) you do not · run `wip clone`\n' "$(wip_other_host)" "$n"
  fi
}

case "${1:-status}" in
  status|"") wip_cmd_status ;;
  push)      shift; wip_cmd_push "$@" ;;
  fetch)     wip_cmd_fetch_all ;;
  diff)      wip_cmd_diff ;;
  pull)      shift; wip_cmd_pull "$@" ;;
  undo)      wip_cmd_undo ;;
  clone)     wip_cmd_clone ;;
  # `|| true` because this `&&` test is the script's LAST command, so under the
  # generated binary's `set -euo pipefail` a false test becomes the exit status:
  # `wip notice` outside a repo measured exit=1 (inside: exit=0). Harmless for
  # the fish hook, which discards it, but wrong for a documented interface --
  # "nothing to report" is not a failure.
  notice)    repo="$(wip_cwd_repo)"; { [ -n "$repo" ] && wip_notice "$repo"; } || true ;;
  *)         echo "usage: wip [status|push [--all]|fetch|diff|pull [--force]|undo|clone]" >&2; exit 1 ;;
esac
