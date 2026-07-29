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

# Fetch only the repos the other machine actually has a snapshot waiting for.
#
# This used to call wip_fetch on EVERY local repo unconditionally, which is one
# ssh connection and one public-key authentication per repo: measured on artemis
# 2026-07-28, 36 connections per tick, 32 of them failing outright with
# "fetch from hub failed" because no bare repo exists on the hub for a slug the
# other machine has never pushed. Every five minutes, on both machines, each
# authentication a credential prompt.
#
# The census the other host publishes already says which slugs have a snapshot
# (see wip_manifest_snapshot_slugs), so ONE round-trip answers the question for
# the whole batch. Against the live manifests on 2026-07-28 that took artemis
# from 36 per-repo connections a tick to 0.
#
# Read ONCE, here, and not inside wip_fetch: per-repo it would cost exactly the
# round-trip it is meant to save, and it would break wip_fetch's contract of
# fetching whatever it is handed.
wip_cmd_fetch_all() {
  local repo slug published nl=$'\n'
  wip_hub_up || return 0
  published="$(wip_manifest_snapshot_slugs "$(wip_other_host)")"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    slug="$(wip_slug "$repo")"
    # Newline-delimited substring match rather than an associative array: this
    # file is sourced by whatever bash the host has, and bash 3.2 (macOS's
    # /bin/bash) has no `declare -A`. Slugs are [a-z0-9-] by construction, so
    # there is nothing for the case pattern to glob on, and the quoting makes it
    # literal regardless.
    case "$nl$published$nl" in
      *"$nl$slug$nl"*) ;;
      # Not in the census, but our shadow still holds a snapshot from the other
      # host: fetch once more so --prune can retire it. See
      # wip_shadow_has_snapshot.
      *) wip_shadow_has_snapshot "$slug" || continue ;;
    esac
    wip_fetch "$repo" || true
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
#
# The ref lives under refs/wip-safety/, NOT refs/wip/, and that is the whole
# point of the odd namespace. wip_fetch fetches 'refs/heads/wip/*:refs/wip/*'
# with --prune, and this ref exists ONLY here -- the hub has never heard of it --
# so inside refs/wip/ every fetch deletes it. Measured:
#
#   before fetch --prune:  refs/wip/other  refs/wip/pre-pull
#   after  fetch --prune:  refs/wip/other
#
# i.e. `wip pull` saved your tree, told you `wip undo` would bring it back, and
# the next five-minute timer tick silently threw it away. Weakening --prune is
# not the fix: it is what retires a snapshot the other host has withdrawn (see
# wip_shadow_has_snapshot). Keeping the safety ref out of the pruned namespace
# is. Anything that reads or writes it must use refs/wip-safety/pre-pull.
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
  if ! git --git-dir="$shadow" update-ref refs/wip-safety/pre-pull "$sha"; then
    printf 'wip: %s: could not write refs/wip-safety/pre-pull\n' "$repo" >&2
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
           || { echo "wip: checkout failed; your tree is saved at refs/wip-safety/pre-pull (\`wip undo\`)." >&2; return 1; }
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
  # refs/wip-safety/, not refs/wip/ -- see wip_safety_ref: the latter is the
  # namespace wip_fetch --prunes, which used to delete this ref within one tick.
  git --git-dir="$shadow" rev-parse --verify --quiet refs/wip-safety/pre-pull >/dev/null 2>&1 \
    || { echo "wip: no pre-pull snapshot for this repo"; return 0; }

  echo "Restoring the tree from $(git --git-dir="$shadow" log -1 --format=%s refs/wip-safety/pre-pull):"
  wip_shadow_diff "$repo" refs/wip-safety/pre-pull --stat
  printf 'Restore? [y/N] '
  read -r reply
  case "$reply" in
    y|Y) # `:/`, not `.` -- same reason as wip_cmd_pull: restore the whole tree
         # regardless of which subdirectory this was run from.
         git --git-dir="$shadow" --work-tree="$repo" checkout refs/wip-safety/pre-pull -- :/
         echo "wip: restored." ;;
    *)   echo "wip: aborted." ;;
  esac
}

# Repos that exist on the other machine but not here.
wip_missing() {
  local other line slug url rel rest
  other="$(wip_other_host)"
  while IFS= read -r line; do
    # Peeled by parameter expansion, NOT read with `IFS=$'\t' read -r slug url
    # rel dirty head` -- the same trap, and the same fix, as
    # wip_manifest_snapshot_slugs in wip.sh; the two must stay consistent. TAB
    # is one of the shell's IFS *whitespace* characters, so `read` collapses a
    # RUN of tabs into a single delimiter even when IFS names nothing else, and
    # the url column is empty for every repo with no `origin`. Such a row
    # arrived shifted one field left: `rel` was read as the dirty flag and
    # `wip clone` offered nonsense like `git clone work/b ~/1` -- i.e. it would
    # have cloned a path as if it were a URL, into a directory named after a
    # boolean.
    #
    # A row with fewer than the manifest's five fields is malformed rather than
    # merely origin-less, and peeling past the end of a string leaves it
    # unchanged (so the last field would silently duplicate into the next one).
    # Require all four separators up front instead.
    case "$line" in *$'\t'*$'\t'*$'\t'*$'\t'*) ;; *) continue ;; esac
    slug="${line%%$'\t'*}"
    [ -n "$slug" ] || continue
    rest="${line#*$'\t'}"               # url onward
    url="${rest%%$'\t'*}"
    [ -n "$url" ] || continue           # no origin: nothing to clone from
    rest="${rest#*$'\t'}"               # rel onward
    rel="${rest%%$'\t'*}"
    [ -n "$rel" ] || continue
    [ -e "$HOME/$rel" ] && continue
    printf '%s\t%s\t%s\n' "$slug" "$url" "$rel"
  done < <(wip_manifest_read "$other")
}

wip_cmd_clone() {
  local slug url rel n=0 reply
  # `IFS=$'\t' read` is safe HERE, unlike against the raw manifest above: this
  # reads wip_missing's own three-column output, and wip_missing skips any row
  # with an empty slug, url or rel -- so there is never a run of tabs to
  # collapse. Point it at a manifest line instead and the bug is back.
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
