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
#
# Three gates, in this order, and the order is the design:
#
#   1. UNKNOWN BASE -- refuse outright (unless --force). Non-interactive.
#   2. DIRTY TREE   -- refuse outright (unless --force). Non-interactive.
#   3. BASE AHEAD   -- warn and take a separate confirmation. Interactive.
#
# Every refusal that can be decided without the user comes BEFORE any prompt, so
# `wip pull` can never ask a question it was going to ignore. Gate 1 precedes
# gate 2 because its remedy (`git fetch`) is free and non-destructive, while
# gate 2's is `--force`, and being told to force your way past a dirty tree
# before being told you are on the wrong base is advice in the wrong order.
wip_cmd_pull() {
  local repo slug shadow force="${1:-}" reply porcelain other base state
  repo="$(wip_cwd_repo)"
  [ -n "$repo" ] || { echo "wip: not in a git repo" >&2; return 1; }
  slug="$(wip_slug "$repo")"; shadow="$(wip_shadow "$slug")"
  other="$(wip_other_host)"
  git --git-dir="$shadow" rev-parse --verify --quiet "refs/wip/$other" >/dev/null 2>&1 \
    || { echo "wip: no snapshot from $other for this repo"; return 0; }

  # See wip_base_state in wip.sh. `none` (no readable base= in the message)
  # deliberately falls through both gates below to the behaviour this command
  # has always had: a snapshot whose message we cannot parse is not evidence of
  # a divergent base, and refusing on it would strand any snapshot written by an
  # older `wip`.
  # `log -1 --format=%s` rather than wip_snapshot_meta: this command wants only
  # the subject, and unlike wip_notice it is not on the cd-hook path, so there
  # is nothing to amortise.
  base="$(wip_snapshot_base \
    "$(git --git-dir="$shadow" log -1 --format=%s "refs/wip/$other" 2>/dev/null)")"
  state="$(wip_base_state "$repo" "$base")"

  # GATE 1. The worst version of this: we hold a tree built on a commit we
  # cannot even see, so there is no way to reason about what applying it means
  # and `wip diff` above the prompt would be comparing unrelated histories.
  if [ "$state" = unknown ]; then
    echo "wip: this snapshot was taken on top of $base, which is not an object in this repo." >&2
    echo "     Run \`git fetch\` first — $other may not have pushed that commit yet." >&2
    if [ "$force" != "--force" ]; then
      echo "     Refusing: applying it would drop $other's files onto a base you cannot see." >&2
      return 1
    fi
    echo "     --force given — continuing onto a base this repo does not have." >&2
  fi

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

  # GATE 3. Not fatal — the other machine's uncommitted work is real and this is
  # the only copy of it — but never silent, and never folded into the ordinary
  # "Apply this snapshot?" prompt below. That prompt is consent to overwrite the
  # tree; this one is consent to do it in the WRONG ORDER, which is a different
  # question and the one the user is getting wrong.
  #
  # Deliberately NOT bypassed by --force. --force in this command means "yes, my
  # working tree is dirty, overwrite it"; reusing it to also mean "yes, apply
  # onto the wrong base" would let one flag wave through two unrelated hazards.
  if [ "$state" = ahead ]; then
    echo "wip: this snapshot was taken on top of $base, which is not in your history."
    echo "     $other has commits you do not. The order that works is \`git pull\` first"
    echo "     for the commits, then \`wip pull\` for the uncommitted work on top."
    echo "     Applying now puts $other's files on your OLDER base, and every commit you"
    echo "     are missing turns into uncommitted changes — \`wip diff\` below is measuring"
    echo "     two trees that are not comparable, so its numbers are not what you think."
    printf 'Apply it anyway, without pulling first? [y/N] '
    # `|| reply=""` so an exhausted stdin aborts with a message rather than
    # taking the generated binary's `set -e` down mid-prompt.
    read -r reply || reply=""
    case "$reply" in
      y|Y) ;;
      *)   echo "wip: aborted."; return 0 ;;
    esac
  fi

  wip_shadow_diff "$repo" "refs/wip/$other" --stat
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
         git --git-dir="$shadow" --work-tree="$repo" checkout "refs/wip/$other" -- :/ \
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

# --- `wip forget` -------------------------------------------------------------
#
# Deleting a repo locally stops its snapshots -- wip_repos only walks what
# exists -- and drops it from the census on the next tick. What it does NOT do is
# collect the three things the repo leaves behind, because nothing in this tool
# ever did:
#
#   <hub>/<slug>.git                    the bare snapshot repo
#   $WIP_CACHE/<slug>.git               this machine's shadow cache
#   $WIP_STATE/<slug>.{tree,created}    this machine's markers
#
# Measured against the live hub on 2026-07-28: 23 bare repos, 3 of them matching
# no repo on either machine.
#
# This is the only verb here that deletes anything outside a working tree, so it
# follows `wip pull`'s discipline exactly: every refusal that can be decided
# without the user comes BEFORE the prompt, the prompt lists what will go and
# from where, and the output is honest about the half that cannot be reached.
#
# The three populations are reconciled through wip_census_index /
# wip_local_index / wip_hub_slugs in wip.sh, each read ONCE: three hub
# round-trips for the whole command, never one per slug.
wip_cmd_forget() {
  local arg="" force=0 list=0 a nl=$'\n'
  local me other mine theirs here hub_slugs live
  local slug="" subject="" repo="" rel orel hrel reply f line shost sts
  local hub_has=0 shadow="" markers="" n=0 total=0

  for a in "$@"; do
    case "$a" in
      --list)  list=1 ;;
      --force) force=1 ;;
      -*)      printf 'wip: forget: unknown option %s\n' "$a" >&2; return 1 ;;
      *)
        if [ -n "$arg" ]; then
          printf 'wip: forget: one repo at a time (got "%s" and "%s")\n' "$arg" "$a" >&2
          return 1
        fi
        arg="$a" ;;
    esac
  done

  # Everything below needs to know what the hub actually holds. There is no
  # honest answer to "what has accumulated?" or "is this slug real?" without it,
  # and guessing is the one thing a destructive verb must not do.
  wip_hub_up || {
    printf 'wip: hub (%s) unreachable — `wip forget` cannot see what it holds.\n' "$WIP_REMOTE_HOST" >&2
    printf 'wip: nothing was changed. Try again on the network.\n' >&2
    return 1
  }

  me="$WIP_HOST"; other="$(wip_other_host)"
  mine="$(wip_census_index   "$(wip_manifest_read "$me")")"
  theirs="$(wip_census_index "$(wip_manifest_read "$other")")"
  here="$(wip_local_index)"
  hub_slugs="$(wip_hub_slugs)"
  # A hub repo is live if ANY of the three says so. The local walk sits
  # alongside our own census rather than replacing it -- see wip_local_index for
  # why our census alone is not enough.
  live="$(wip_index_slugs "$mine"; wip_index_slugs "$theirs"; wip_index_slugs "$here")"

  # --- `--list`: change nothing, just say what has accumulated ----------------
  if [ "$list" -eq 1 ]; then
    [ -z "$arg" ] || { printf 'wip: forget: --list takes no argument\n' >&2; return 1; }
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      total=$((total+1))
      case "$nl$live$nl" in *"$nl$slug$nl"*) continue ;; esac
      [ "$n" -gt 0 ] || printf 'Hub (%s) repos with no live repo on %s or %s:\n\n' \
        "$WIP_REMOTE_HOST" "$me" "$other"
      n=$((n+1))
      # A path is only on record for a slug some census still lists, so a
      # genuine orphan usually has none. Print the slug alone rather than
      # reversing it into a guess: wip_slug's path fallback is lossy, and a `-`
      # in a slug could have been `/`, `.` or `_`.
      rel="$(wip_index_path "$slug" "$mine" || wip_index_path "$slug" "$theirs" || true)"
      if [ -n "$rel" ]; then printf '  %-48s last seen at ~/%s\n' "$slug" "$rel"
      else                   printf '  %s\n' "$slug"; fi
    done <<< "$hub_slugs"
    if [ "$n" -eq 0 ]; then
      printf 'wip: nothing orphaned — all %d hub repo(s) match a live repo.\n' "$total"
    else
      printf '\n%d of %d hub repo(s) orphaned. `wip forget <slug>` removes one.\n' "$n" "$total"
    fi
    return 0
  fi

  # --- which slug -------------------------------------------------------------
  if [ -n "$arg" ]; then
    slug="$(wip_slug_from_arg "$arg")"; subject="$arg"
  else
    repo="$(wip_cwd_repo)"
    [ -n "$repo" ] || {
      printf 'wip: not in a git repo — name a slug, or run `wip forget --list` to see what the hub holds.\n' >&2
      return 1
    }
    slug="$(wip_slug "$repo")"; subject="$repo"
  fi
  # Slugs are [a-z0-9-] by construction (wip_slug_normalize's final sed).
  # Anything else means the derivation produced something that is not a slug,
  # and this is the gate that keeps such a value out of the remote `rm -rf` in
  # wip_hub_rm_repo.
  case "$slug" in
    ''|*[!a-z0-9-]*)
      printf 'wip: forget: "%s" does not reduce to a slug (got "%s") — refusing.\n' "$subject" "$slug" >&2
      return 1 ;;
  esac

  # --- what actually exists for it --------------------------------------------
  case "$nl$hub_slugs$nl" in *"$nl$slug$nl"*) hub_has=1 ;; esac
  shadow="$(wip_shadow "$slug")"
  [ -d "$shadow" ] || shadow=""
  # `if`, not `[ -e "$f" ] && markers=...`: the generated binary runs under
  # `set -e`, and when the last iteration's test is false the loop's own status
  # is that failure. It happens to be exempt (the failing command is not the one
  # following the final `&&`), but relying on which side of that exemption a
  # line falls is how this tool has been bitten before -- see the `|| true` on
  # the `notice` verb in the dispatcher below.
  for f in "$WIP_STATE/$slug.tree" "$WIP_STATE/$slug.created"; do
    if [ -e "$f" ]; then markers="${markers:+$markers$nl}$f"; fi
  done

  # Nothing anywhere. This is the "do not silently guess" case: an argument that
  # normalised to a slug nobody has ever heard of must say so, not shrug and
  # report success.
  if [ "$hub_has" -eq 0 ] && [ -z "$shadow" ] && [ -z "$markers" ]; then
    printf 'wip: nothing to forget — the hub has no "%s.git", and this machine has no cache or markers for it.\n' \
      "$slug" >&2
    [ "$slug" = "$subject" ] || printf 'wip: ("%s" reduced to the slug "%s".)\n' "$subject" "$slug" >&2
    printf 'wip: `wip forget --list` shows what the hub actually holds.\n' >&2
    return 1
  fi

  # The main way to misuse this verb, and the reason it is a refusal rather than
  # a warning: whatever we delete from the hub, the other machine's next tick
  # puts straight back. This is not "are you sure", it is "that will not work".
  if orel="$(wip_index_path "$slug" "$theirs")"; then
    printf 'wip: %s still has this repo%s.\n' "$other" "${orel:+, at ~/$orel}" >&2
    printf 'wip: deleting the hub copy achieves nothing — %s recreates it on its next tick.\n' "$other" >&2
    if [ "$force" -ne 1 ]; then
      printf 'wip: delete the repo on %s first, or re-run with --force.\n' "$other" >&2
      return 1
    fi
    printf 'wip: --force given — continuing anyway.\n' >&2
  fi

  # Our own side is a NOTE, not a refusal. `wip forget` with no argument is run
  # from INSIDE the repo by design -- typically in the moment before deleting it
  # -- and refusing there would make that form useless.
  if hrel="$(wip_index_path "$slug" "$here")"; then
    printf 'wip: note — this repo still exists here, at ~/%s. This machine will recreate\n' "$hrel"
    printf 'wip:        the hub repo on its next tick unless you delete the repo too.\n'
  fi

  # --- confirm, naming every path and where it lives --------------------------
  printf 'wip: forget "%s" — this removes:\n' "$slug"
  # A fixed-width label column, so the three destinations line up whatever the
  # hub is called -- this is the list the user is consenting to.
  if [ "$hub_has" -eq 1 ]; then
    printf '  %-14s %s/%s.git\n' "hub ($WIP_REMOTE_HOST)" "$WIP_REMOTE_PATH" "$slug"
    # A bare repo that still holds a snapshot is not just clutter. Once both
    # machines have deleted the repo, this is the ONLY place that uncommitted
    # work exists -- nothing was committed, no shadow cache is refreshed for it
    # and `wip undo` cannot reach it. Say so before the prompt, not after.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      shost="${line%%$'\t'*}"; sts="${line##*$'\t'}"
      case "$sts" in ''|*[!0-9]*) sts="" ;; esac
      if [ -n "$sts" ]; then
        printf '     !! it still holds a snapshot from %s, %s old — deleting it ends that work\n' \
          "$shost" "$(wip_human_age "$(( $(date +%s) - sts ))")"
      else
        printf '     !! it still holds a snapshot from %s — deleting it ends that work\n' "$shost"
      fi
    done <<< "$(wip_hub_snapshots "$slug")"
  else
    printf '  %-14s (nothing — no %s.git there)\n' "hub ($WIP_REMOTE_HOST)" "$slug"
  fi
  if [ -n "$shadow" ]; then printf '  %-14s %s\n' "shadow cache" "$shadow"
  else                      printf '  %-14s (nothing)\n' "shadow cache"; fi
  if [ -n "$markers" ]; then
    while IFS= read -r f; do printf '  %-14s %s\n' "marker" "$f"; done <<< "$markers"
  else
    printf '  %-14s (nothing)\n' "markers"
  fi
  # This verb NEVER touches the repo itself, even when run from inside one, and
  # the list above is the promise -- so say so where the user is deciding.
  printf '  (the repository itself is not touched)\n'
  printf 'Remove them? [y/N] '
  # `|| reply=""` so an exhausted stdin aborts with a message rather than taking
  # the generated binary's `set -e` down mid-prompt, as in wip_cmd_pull.
  read -r reply || reply=""
  case "$reply" in y|Y) ;; *) echo "wip: aborted."; return 0 ;; esac

  # Hub first, and abort outright if it fails: leaving the hub repo while
  # deleting the local cache and markers is the worst of both, since the next
  # tick would re-fetch it and the user would be told it was forgotten.
  if [ "$hub_has" -eq 1 ] && ! wip_hub_rm_repo "$slug"; then
    printf 'wip: could not remove %s/%s.git from the hub — nothing else was touched.\n' \
      "$WIP_REMOTE_PATH" "$slug" >&2
    return 1
  fi
  [ -z "$shadow" ] || rm -rf "$shadow"
  if [ -n "$markers" ]; then
    while IFS= read -r f; do rm -f "$f"; done <<< "$markers"
  fi

  printf 'wip: forgotten "%s".\n' "$slug"
  # The half this command cannot reach. Nothing in this tool ever ssh's into the
  # other machine -- there is no credential for it and no reason to invent one
  # for a cleanup verb -- so name what is left rather than implying it is done.
  printf 'wip: NOT cleaned: the shadow cache and markers on %s — this command cannot reach\n' "$other"
  printf 'wip:              that machine. Run `wip forget %s` there too.\n' "$slug"
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
  forget)    shift; wip_cmd_forget "$@" ;;
  # `|| true` because this `&&` test is the script's LAST command, so under the
  # generated binary's `set -euo pipefail` a false test becomes the exit status:
  # `wip notice` outside a repo measured exit=1 (inside: exit=0). Harmless for
  # the fish hook, which discards it, but wrong for a documented interface --
  # "nothing to report" is not a failure.
  notice)    repo="$(wip_cwd_repo)"; { [ -n "$repo" ] && wip_notice "$repo"; } || true ;;
  *)         echo "usage: wip [status|push [--all]|fetch|diff|pull [--force]|undo|clone|forget [<slug>|--list] [--force]]" >&2; exit 1 ;;
esac
