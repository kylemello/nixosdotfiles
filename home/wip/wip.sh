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
#   WIP_SSH_IDENTITY the dedicated hub key; empty = pass no -i (tests)
#   WIP_SSH_CONTROL  ControlPath for connection multiplexing; empty = off (tests)
#
# EVERY ssh invocation below goes through wip_hub_ssh -- not bare `ssh`, and not
# a bare "${WIP_SSH:-ssh}" either. See that function for what it adds and why
# leaving one call site out costs a whole extra SSH handshake per tick.

# Normalize a repo to a stable slug. Derived from `origin` rather than the
# directory name, because the same project has different directory names on
# each machine (DocResolve-brrit-com vs DocResolve-brrit.com). Falls back to
# the $HOME-relative path for repos with no origin.
wip_slug() {
  local repo="$1" url
  url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  if [ -n "$url" ]; then
    wip_slug_normalize "$url"
  else
    printf '%s' "${repo#"$HOME"/}" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's#[^a-z0-9]+#-#g; s#^-+##; s#-+$##'
  fi
}

# The normalisation half of wip_slug, over a bare STRING rather than a repo on
# disk. Split out for `wip forget`, which has to derive a slug when the repo has
# ALREADY been deleted -- which is the usual case, since cleaning up after a
# deleted repo is the whole point of that verb.
#
# Only wip_slug's URL branch delegates here, and the path branch deliberately
# does NOT: this pipeline strips a trailing `.git`, so a repo DIRECTORY named
# `foo.git` would change slug and stop pairing with the snapshot already on the
# hub. The two branches have always differed in exactly that one way; folding
# them together would silently re-slug deployed repos.
wip_slug_normalize() {
  printf '%s' "$1" \
    | sed -E 's#^[a-z+]+://##; s#^[^@/]+@##; s#:#/#; s#\.git$##' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#[^a-z0-9]+#-#g; s#^-+##; s#-+$##'
}

# A slug from whatever `wip forget` was handed: a slug, a path, or a URL.
#
# A LIVE repo on disk is resolved through wip_slug, not normalised as a string,
# and that ordering matters: `wip forget ~/work/demo` on a repo whose origin is
# github.com/acme/Demo-App has to give `github-com-acme-demo-app`, where the
# string alone would give `work-demo` -- a slug the hub has never heard of.
#
# Everything else goes through wip_slug_normalize, which is a no-op on something
# that is already a slug (lowercase [a-z0-9-], no scheme, no `@`, no `:`, no
# `.git` suffix), so the ordinary `wip forget <slug>` passes through untouched.
# Guessing is bounded by the CALLER, not here: a value that normalises to
# something the hub does not hold and that has nothing local is reported as
# such, never acted on.
wip_slug_from_arg() {
  local arg="$1" top s
  # `git -C ""` is a documented NO-OP rather than an error, so an empty argument
  # would fall through to the branch below and resolve the CURRENT repo -- a
  # silently wrong answer from the one function whose job is to name what is
  # about to be deleted. wip_cmd_forget routes an empty argument to its own cwd
  # branch before ever calling this, so this is belt-and-braces for a future
  # caller that does not.
  [ -n "$arg" ] || return 0
  if top="$(git -C "$arg" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
    wip_slug "$top"
    return 0
  fi
  s="${arg%/}"          # a trailing slash, as shell tab-completion leaves it
  s="${s#"$HOME"/}"     # ~/work/foo -> work/foo, as wip_slug's path branch does
  wip_slug_normalize "$s"
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

# The ONE way this file talks to the hub over ssh. Two things it adds, both of
# which have to be on every single call site or they may as well not be there:
#
# 1. -i / IdentitiesOnly=yes. The hub is reached with a DEDICATED on-disk key
#    (~/.ssh/wip_hub_ed25519), not the 1Password agent. A five-minute timer
#    authenticating with a credential that exists to ask a human for approval is
#    the wrong shape: it produced an approval prompt per repo per tick. The
#    IdentitiesOnly=yes is not decoration -- without it ssh still offers every
#    agent key first (ariane's ~/.ssh/config sets `IdentityAgent` for `Host *`),
#    the agent signs, and the prompt is back even though -i was passed.
#
# 2. ControlMaster/ControlPath/ControlPersist. Without multiplexing this tool
#    opens one TCP connection and one public-key authentication PER REPO -- ~36
#    on artemis, ~23 on ariane, every five minutes. With it, every ssh in a tick
#    (this file's direct calls AND git's, via GIT_SSH_COMMAND, which home/wip.nix
#    gives the same options) rides one connection: the first call authenticates
#    and forks a master, the rest attach to its socket.
#
# ControlPersist is deliberately short (60s): it only has to outlive one tick.
# systemd's oneshot unit kills the master when the tick's ExecStart exits
# anyway, which is fine -- the sharing that matters is WITHIN a tick.
#
# Both are opt-in via the environment so the test suite (which drives a local
# directory as the hub, and stubs ssh where it does not) is unaffected by
# default, and so sourcing this file by hand never writes a socket somewhere
# unexpected.
wip_hub_ssh() {
  local ssh="${WIP_SSH:-ssh}" ctldir
  local -a opts=()
  if [ -n "${WIP_SSH_IDENTITY:-}" ]; then
    opts+=(-i "$WIP_SSH_IDENTITY" -o IdentitiesOnly=yes)
  fi
  if [ -n "${WIP_SSH_CONTROL:-}" ]; then
    # ssh does NOT create the ControlPath's parent, and a missing one is fatal
    # (bind() ENOENT), not a graceful fallback -- so on a machine whose state dir
    # has not been created yet this would take out every hub operation rather
    # than just the multiplexing. Parameter expansion, not `dirname`: this runs
    # on every ssh call and there is no reason to fork for it.
    ctldir="${WIP_SSH_CONTROL%/*}"
    [ -d "$ctldir" ] || mkdir -p "$ctldir" 2>/dev/null || true
    opts+=(-o ControlMaster=auto -o "ControlPath=$WIP_SSH_CONTROL" -o ControlPersist=60)
  fi
  # ${opts[@]+"${opts[@]}"} and not "${opts[@]}": an empty array under `set -u`
  # is an unbound-variable error in bash before 4.4, and the generated `wip`
  # binary runs with `set -euo pipefail`.
  "$ssh" ${opts[@]+"${opts[@]}"} "$@"
}

# --- last successful hub contact ---------------------------------------------
#
# No per-tick classification of ssh's exit status can ever be complete:
# wip_hub_up below distinguishes the failures it KNOWS about, and a novel one
# still lands in the quiet bucket by design (see its 255 block). This stamp is
# the backstop that turns "quiet" into something observable -- `wip` can say
# "last reached the hub 3 days ago" instead of the user having to infer a
# problem from an absence of output. Three separate silent-timer bugs in this
# tool's history (exit 127, exit 126, exit 255-from-auth) would all have been
# visible in one glance at this.
#
# It records REACHABILITY, not a successful push: wip_hub_up is the only writer.
wip_hub_stamp() { printf '%s/last-hub-contact' "$WIP_STATE"; }

# Seconds since the last successful hub contact. Empty when there has never
# been one -- the first-deploy case, and the loudest thing this can report.
wip_hub_last_age() {
  local f ts
  f="$(wip_hub_stamp)"
  [ -f "$f" ] || return 0
  ts="$(cat "$f" 2>/dev/null)" || return 0
  # A truncated or hand-edited stamp must read as "no stamp", never as epoch 0
  # -- that would be a 56-year-old contact and a warning that never clears.
  case "$ts" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$(( $(date +%s) - ts ))"
}

# One-line staleness warning for the `wip` status verb, or nothing at all.
wip_hub_staleness() {
  # Meaningless against a local-directory hub (tests only): there is no network
  # to be away from and wip_hub_up never probes, so it would never be stamped.
  wip_local_hub && return 0
  local age
  age="$(wip_hub_last_age)"
  if [ -z "$age" ]; then
    printf 'wip: has NEVER reached the hub (%s) — nothing is being pushed or fetched.\n' \
      "$WIP_REMOTE_HOST"
    return 0
  fi
  # 24h, not the "few hours" the review suggested: a whole day off the LAN is an
  # ordinary week at the office for ariane, and a warning that fires on every
  # ordinary day is one nobody reads.
  [ "$age" -ge 86400 ] || return 0
  printf 'wip: last reached the hub (%s) %s ago — snapshots are not syncing.\n' \
    "$WIP_REMOTE_HOST" "$(wip_human_age "$age")"
}

# Does this probe stderr describe a fault at OUR end rather than an absent hub?
#
# Split out from wip_hub_up so the classification is one readable list and can
# be driven directly from the test suite. Deliberately a POSITIVE match on
# local faults -- see wip_hub_up's 255 block for why the default is silence.
wip_ssh_local_fault() {
  case "$1" in
    *"Permission denied"*)                    return 0 ;;
    *"signing failed"*)                       return 0 ;;
    *"communication with agent failed"*)      return 0 ;;
    *"agent refused operation"*)              return 0 ;;
    *"Too many authentication failures"*)     return 0 ;;
    *"No such identity"*)                     return 0 ;;
    *"Host key verification failed"*)         return 0 ;;
    *"HOST IDENTIFICATION HAS CHANGED"*)      return 0 ;;
  esac
  return 1
}

# Is the hub reachable right now? gateway is LAN-only — no tailnet node
# advertises 10.11.12.0/24 (verified 2026-07-28), so ariane can only reach it on
# the home network or over UniFi Teleport. An unreachable hub is therefore the
# NORMAL case, not an error, and must be cheap to detect: without this probe,
# 22 repos x SSH's ~75s TCP default would hang the timer for ~27 minutes and
# overlapping runs would pile up.
wip_hub_up() {
  wip_local_hub && return 0
  local ssh="${WIP_SSH:-ssh}" status=0 err
  # stderr is CAPTURED rather than discarded (stdout goes to /dev/null; the
  # remote command is `true` and has none) because the exit status alone cannot
  # tell the two kinds of 255 apart -- see below. `|| status=$?` rather than a
  # bare call plus `$?`: this must read the same under `set -e` no matter how
  # the caller invoked us.
  err="$(wip_hub_ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
      "$WIP_REMOTE_HOST" true 2>&1 >/dev/null)" || status=$?

  if [ "$status" -eq 0 ]; then
    # Stamp every success, so `wip` can report the age of the last contact.
    # Best-effort: a state dir we cannot write is not a reason to fail a tick
    # that otherwise worked.
    mkdir -p "$WIP_STATE" 2>/dev/null && date +%s > "$(wip_hub_stamp)" 2>/dev/null || true
    return 0
  fi

  # 255 is OpenSSH's reserved status for its own failures -- and it covers two
  # completely unrelated events. "Cannot reach the host" is the NORMAL case for
  # a LAN-only hub and must stay silent. "The host rejected my key" is a fault
  # at this end and must be loud, or the timer runs every five minutes forever
  # pushing nothing and logging nothing. Measured on artemis from a systemd user
  # unit, with a key that gateway does authorize:
  #
  #   sign_and_send_pubkey: signing failed for ED25519 "..." from agent:
  #     communication with agent failed
  #   kyle@10.11.12.105: Permission denied (publickey,password,keyboard-interactive).
  #   exit = 255
  #
  # (The Windows 1Password agent would not SIGN from a non-interactive session.)
  # To an exit status alone that is indistinguishable from a sleeping hub, and
  # main.sh's `wip_hub_up || return 0` turns it straight into a silent exit 0 --
  # the third distinct route to the same silent-timer bug, after 127 and 126.
  #
  # The stderr text is what separates them. Unlike the allow-list below, this is
  # a positive match on LOCAL faults and anything else at 255 stays quiet, on
  # purpose: ssh's connection-failure wording is open-ended ("No route to host",
  # "Operation timed out", "kex_exchange_identification", bare "Connection
  # closed by ..."), and a five-minute timer that cries wolf about a laptop
  # being off the LAN is a timer nobody reads. wip_hub_staleness above is the
  # backstop for whatever this list misses: an unrecognised 255 leaves the stamp
  # untouched, so `wip` reports the age and the user sees it without grepping a
  # journal.
  if [ "$status" -eq 255 ]; then
    if wip_ssh_local_fault "$err"; then
      # "a local reason", not "authentication": the list also covers a CHANGED
      # host key, which is a different (and more alarming) thing entirely.
      printf 'wip: ssh to %s FAILED for a LOCAL reason (key, agent or host key) — not a sleeping hub.\n' \
        "$WIP_REMOTE_HOST" >&2
      printf 'wip: ssh said: %s\n' "$(printf '%s' "$err" | tr '\n' ' ')" >&2
      printf 'wip: nothing can be pushed or fetched until this is fixed — aborting.\n' >&2
      # `exit`, not `return`, for the same reason as the misconfiguration path
      # below: every caller swallows a non-zero wip_hub_up as "hub away".
      exit "$status"
    fi
    return 255
  fi

  # A sleeping hub and a broken local ssh MUST NOT look alike.
  #
  # The probe used to send its stderr to /dev/null, because a LAN-only hub being
  # away is the normal case and must stay quiet. That redirection also swallowed
  # the SHELL's own "command not found", so a misconfigured WIP_SSH used to
  # arrive here as a plain non-zero and be reported as "hub away" -- measured:
  # `wip push --all` exited 0 with no output at all, so the timer would push
  # nothing and log nothing, every 5 minutes, forever. It survives manual
  # testing too: `ssh.exe` resolves in an interactive fish (home.sessionPath)
  # but not in a systemd user unit, which is where the timer runs.
  #
  # Everything below this point is reached by ELIMINATION, and that is
  # deliberate: the two branches above are an ALLOW-LIST, not a list of bad
  # statuses. The probe runs `true`, so the only statuses a healthy setup can
  # produce are 0 (hub answered) and 255 (OpenSSH's own failures). Anything else
  # came from this end and is a misconfiguration. Enumerating the BAD codes
  # instead would get it the wrong way round: any code left off such a list
  # would return quietly, and main.sh's `wip_hub_up || return 0` launders a
  # quiet non-zero straight into a silent exit 0. That is how 126 -- the status
  # for a binary that EXISTS but cannot be executed, exactly what broken WSL
  # binfmt interop does to ssh.exe ("Exec format error") -- would have walked
  # back in through a different door after 127 was closed.

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
    wip_hub_ssh "$WIP_REMOTE_HOST" "git init --bare -q '$WIP_REMOTE_PATH/$slug.git' 2>/dev/null || true"
  fi
  mkdir -p "$WIP_STATE"; : > "$flag"
}

# Every slug the hub holds a bare snapshot repo for, one per line.
#
# ONE round trip for the whole hub. `wip forget --list` cross-references this
# against both censuses, and a per-slug probe would be the same mistake
# wip_cmd_fetch_all in main.sh exists to undo.
#
# `ls` of the DIRECTORY plus a suffix test here, rather than a remote
# `ls -d '$WIP_REMOTE_PATH'/*.git`: an unmatched glob comes back as the literal
# pattern, so a hub holding nothing yet would report a repo named `*` -- which
# `wip forget` would then offer to delete. The suffix test also drops
# `_manifest/`, which is a directory on the hub but not a snapshot repo.
wip_hub_slugs() {
  local out line
  if wip_local_hub; then
    out="$(ls -1 "$WIP_REMOTE_PATH" 2>/dev/null || true)"
  else
    out="$(wip_hub_ssh "$WIP_REMOTE_HOST" "ls -1 '$WIP_REMOTE_PATH' 2>/dev/null" || true)"
  fi
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    case "$line" in *.git) printf '%s\n' "${line%.git}" ;; esac
  done <<< "$out"
}

# What snapshots the hub's bare repo for a slug still holds: one
# "<host><TAB><unix-time>" line per refs/heads/wip/<host>.
#
# ONE round trip, and only on `wip forget`'s destructive path -- `--list` never
# pays for it.
#
# This is not decoration. Once BOTH machines have deleted a repo, the hub's bare
# repo is the only place its uncommitted work still exists: no working tree has
# it, no shadow cache is refreshed for it, `wip undo` cannot reach it, and
# nothing was ever committed. Deleting it is final. Measured against the live hub
# on 2026-07-28: all three of its orphans still held a 4-hour-old snapshot, so
# this is the ordinary case for an orphan rather than a corner of it.
#
# `%09` rather than a literal tab in the format string, so the value survives
# being interpolated into a remote shell command.
wip_hub_snapshots() {
  local slug="$1" fmt='%(refname:strip=3)%09%(committerdate:unix)'
  if wip_local_hub; then
    git --git-dir="$WIP_REMOTE_PATH/$slug.git" for-each-ref \
      --format="$fmt" refs/heads/wip/ 2>/dev/null || true
  else
    wip_hub_ssh "$WIP_REMOTE_HOST" \
      "git --git-dir='$WIP_REMOTE_PATH/$slug.git' for-each-ref --format='$fmt' refs/heads/wip/ 2>/dev/null" \
      || true
  fi
}

# Delete one bare snapshot repo from the hub.
#
# Through wip_hub_ssh like every other hub operation -- see its header for why a
# bare `ssh` here costs a whole extra handshake. The slug is validated as
# [a-z0-9-] by wip_cmd_forget BEFORE this is reached, and that validation is
# what makes interpolating it into a remote `rm -rf` safe; nothing else may call
# this with an unvalidated value.
wip_hub_rm_repo() {
  local slug="$1"
  if wip_local_hub; then
    rm -rf "$WIP_REMOTE_PATH/$slug.git"
  else
    wip_hub_ssh "$WIP_REMOTE_HOST" "rm -rf '$WIP_REMOTE_PATH/$slug.git'"
  fi
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

# Does the shadow cache still hold a snapshot ref from the other host?
#
# Purely local -- no network. This exists so the census filter in
# wip_cmd_fetch_all cannot strand a WITHDRAWN snapshot. When the other host
# commits its work its tree goes clean, wip_snapshot deletes the hub ref and the
# census flips to dirty=0; a filter that only looked at the census would then
# never fetch that slug again, and the stale refs/wip/<other> in our shadow would
# keep `wip notice` announcing a snapshot that no longer exists (and `wip pull`
# offering to apply it). One more fetch prunes the ref, after which this returns
# false and the slug drops out of the batch for good -- self-terminating, so it
# costs nothing in the steady state.
wip_shadow_has_snapshot() {
  local shadow; shadow="$(wip_shadow "$1")"
  [ -d "$shadow" ] || return 1
  git --git-dir="$shadow" rev-parse --verify --quiet "refs/wip/$(wip_other_host)" >/dev/null 2>&1
}

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
  local repo slug url rel dirty head out remote_dest remote_tmp porcelain rc=0
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
    # `--no-optional-locks` is load-bearing, not tidiness. This tool's ONE hard
    # promise is that it never touches the user's repo, and a plain `git status`
    # REWRITES .git/index whenever the stat cache is stale -- taking
    # .git/index.lock to do it. This line runs against every repo on every
    # five-minute tick, so without the flag the timer both breaks that promise
    # and races whatever git command the user is running at that moment
    # ("Unable to create '.git/index.lock': File exists"). Measured: the index
    # cksum changes across an unflagged call and is byte-identical with it.
    #
    # The EXIT STATUS is checked, not just the output: an empty stdout from a
    # FAILED status is indistinguishable from a clean tree, so a repo with a
    # corrupt index used to be published as dirty=0 -- "there is nothing waiting
    # here" -- which is the exact opposite of the truth. Omit the repo instead
    # and say so; the other host's `wip clone` only ever ADDS repos it lacks, so
    # a short census is conservative where a wrong one is not.
    if ! porcelain="$(git --no-optional-locks -C "$repo" status --porcelain)"; then
      printf 'wip: %s: git status failed; omitting it from the census\n' "$repo" >&2
      rc=1
      continue
    fi
    if [ -z "$porcelain" ]; then dirty=0; else dirty=1; fi
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
    if ! wip_hub_ssh "$WIP_REMOTE_HOST" \
        "mkdir -p '$WIP_REMOTE_PATH/_manifest' && cat > '$remote_tmp'" < "$out"; then
      printf 'wip: manifest: hub unreachable, not published\n' >&2
      rm -f "$out"
      wip_hub_ssh "$WIP_REMOTE_HOST" "rm -f '$remote_tmp'" 2>/dev/null || true
      return 1
    fi
    rm -f "$out"
    if ! wip_hub_ssh "$WIP_REMOTE_HOST" "mv '$remote_tmp' '$remote_dest'"; then
      printf 'wip: manifest: hub unreachable, not published\n' >&2
      wip_hub_ssh "$WIP_REMOTE_HOST" "rm -f '$remote_tmp'" 2>/dev/null || true
      return 1
    fi
  fi
  # Non-zero if any repo was omitted above. The census that DID get published is
  # still the best available one, so it is published either way -- but a caller
  # must not read "published" as "complete".
  return "$rc"
}

# Read another host's manifest. A missing file just means that host hasn't
# published a census yet (e.g. first run) -- not an error worth failing on --
# so this still returns success with empty output in that case.
wip_manifest_read() {
  local host="$1"
  if wip_local_hub; then
    cat "$(wip_manifest_path "$host")" 2>/dev/null || true
  else
    wip_hub_ssh "$WIP_REMOTE_HOST" "cat '$(wip_manifest_path "$host")' 2>/dev/null" || true
  fi
}

# The slugs the other host currently has a snapshot waiting on the hub for.
#
# The census carries a `dirty` column, and dirty is exactly the condition under
# which wip_snapshot pushes: a clean tree makes it DELETE its hub ref instead.
# So dirty=1 is the manifest's answer to "is there a snapshot for this slug",
# and it is the only answer available without one ssh round-trip per repo --
# which is the whole point (see wip_cmd_fetch_all in main.sh).
#
# Reads the census ONCE. Callers must not invoke this per repo.
#
# Split by parameter expansion and NOT by `IFS=$'\t' read -r slug url rel dirty
# head`, which is the obvious way to write this and is wrong. TAB is one of the
# shell's IFS *whitespace* characters, so a run of them collapses into a single
# delimiter no matter that IFS names only the tab -- and the url column is empty
# for every repo with no `origin`. Measured against the live ariane census on
# 2026-07-28: `IFS=$'\t' read` shifted those rows left by one and read the head
# SHA as the dirty flag, silently dropping 2 of 7 waiting snapshots
# (personal-inventori, personal-laravel-app) -- exactly the repos whose only copy
# is the other machine's. Trailing fields are not needed, so peel four.
wip_manifest_snapshot_slugs() {
  local host="$1" line slug rest dirty
  while IFS= read -r line; do
    slug="${line%%$'\t'*}"
    [ -n "$slug" ] || continue
    rest="${line#*$'\t'}"    # url onward
    rest="${rest#*$'\t'}"    # rel onward
    rest="${rest#*$'\t'}"    # dirty onward
    dirty="${rest%%$'\t'*}"
    [ "$dirty" = "1" ] || continue
    printf '%s\n' "$slug"
  done < <(wip_manifest_read "$host")
}

# --- who still has what -------------------------------------------------------
#
# `wip forget` has to answer one question -- "does a live repo still correspond
# to this bare repo on the hub?" -- across three populations at once: this
# machine, the other machine, and the hub itself. The two functions below reduce
# the first two to one common shape, "<slug>\t<$HOME-relative path>", so a
# single pair of lookups serves both. Each population is read EXACTLY ONCE per
# `wip forget`, never once per slug.

# A census blob (as wip_manifest_read returns it) reduced to that shape.
#
# The SLUG is emitted for every row with a non-empty first field, INCLUDING a
# malformed one; only the PATH is gated on the full five columns. That asymmetry
# is deliberate and it points the safe way. The slug set is what decides whether
# a hub repo counts as orphaned -- i.e. whether `wip forget` will offer to
# DELETE it -- so a row this parser cannot fully read must still count as "that
# repo exists"; dropping it would make a live repo look deletable. The path is
# only ever displayed, and peeling past the end of a short row leaves the string
# unchanged, which would print the url as if it were the path.
#
# Peeled by parameter expansion and NOT `IFS=$'\t' read -r slug url rel ...`:
# TAB is one of the shell's IFS *whitespace* characters, so a run of tabs
# collapses into a single delimiter, and the url column is empty for every repo
# with no `origin`. Same trap and the same fix as wip_manifest_snapshot_slugs
# above and wip_missing in main.sh; all three have to stay consistent.
wip_census_index() {
  local blob="$1" line slug rest
  [ -n "$blob" ] || return 0
  while IFS= read -r line; do
    slug="${line%%$'\t'*}"
    [ -n "$slug" ] || continue
    case "$line" in
      *$'\t'*$'\t'*$'\t'*$'\t'*)
        rest="${line#*$'\t'}"          # url onward
        rest="${rest#*$'\t'}"          # rel onward
        printf '%s\t%s\n' "$slug" "${rest%%$'\t'*}" ;;
      *) printf '%s\t\n' "$slug" ;;
    esac
  done <<< "$blob"
}

# The same shape for THIS machine, computed from the filesystem rather than from
# our own census on the hub.
#
# Not a shortcut for reading our own manifest, and not interchangeable with it.
# That manifest is only as fresh as the last tick that actually reached the hub,
# and wip_manifest_write deliberately OMITS any repo whose `git status` failed.
# Either gap would show a repo sitting right here as an orphan -- and orphans are
# what `wip forget` deletes.
wip_local_index() {
  local repo
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    printf '%s\t%s\n' "$(wip_slug "$repo")" "${repo#"$HOME"/}"
  done < <(wip_repos)
}

# Just the slugs of such an index.
wip_index_slugs() {
  local index="$1" line
  [ -n "$index" ] || return 0
  while IFS= read -r line; do
    [ -n "${line%%$'\t'*}" ] && printf '%s\n' "${line%%$'\t'*}"
  done <<< "$index"
  return 0
}

# The path recorded for one slug in such an index. Prints it -- possibly empty --
# and returns 0 when the slug is PRESENT; returns 1 when it is absent. Presence
# and path are different questions, and a repo with no recorded path must not
# read as an absent one: that is the difference between refusing to delete the
# other machine's live repo and deleting it.
wip_index_path() {
  local slug="$1" index="$2" line
  [ -n "$index" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "$slug"$'\t'*) printf '%s' "${line#*$'\t'}"; return 0 ;;
    esac
  done <<< "$index"
  return 1
}

# Pull the other host's snapshot into a shadow repo under $WIP_CACHE. The real
# repo is never opened for writing, so it gains no refs and no objects.
#
# Same discipline as wip_snapshot: an unreachable hub (the normal case off
# the home LAN) or a shadow repo that can't be created/fetched into must be
# reported non-zero with a diagnostic, not swallowed as success -- a caller
# that trusts a silent "ok" here would tell the user their WIP is current
# when nothing was actually fetched.
#
# UNCONDITIONAL by contract: given a repo, it fetches, full stop. The decision
# about WHICH repos are worth a connection belongs to the batch caller
# (wip_cmd_fetch_all), which can amortise one census read over all of them;
# moving it in here would mean one ssh round-trip per repo to answer a question
# one round-trip already answers for the lot. Single-repo callers (and the test
# suite) depend on this staying unconditional.
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
  # --prune owns refs/wip/* OUTRIGHT: any ref under it that the hub does not
  # have is deleted here, every tick. That is deliberate (it is what retires a
  # snapshot the other host withdrew -- see wip_shadow_has_snapshot), so nothing
  # purely local may be stored in this namespace. `wip undo`'s safety ref learnt
  # that the hard way and now lives in refs/wip-safety/ (see wip_safety_ref).
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

# Everything wip_notice needs to know about the other host's snapshot, from ONE
# `git log`: when it was taken (%ct) and what it says about itself (%s, which is
# where wip_snapshot records the base commit). Two lines — timestamp, then
# subject — or nothing at all when there is no such ref.
#
# One invocation rather than one per field, because this sits on the fish
# cd-hook path. Measured on ariane against a 120-file fixture: a second `git log`
# here costs ~5 ms of a ~55 ms notice, i.e. as much as the base classification it
# exists to feed. Splitting is done by parameter expansion, which forks nothing.
wip_snapshot_meta() {
  git --git-dir="$1" log -1 --format='%ct%n%s' "refs/wip/$2" 2>/dev/null || true
}

wip_human_age() {
  local s="$1"
  if   [ "$s" -lt 90 ];    then printf '%d sec' "$s"
  elif [ "$s" -lt 5400 ];  then printf '%d min' "$(( s / 60 ))"
  elif [ "$s" -lt 172800 ];then printf '%d hr'  "$(( s / 3600 ))"
  else                          printf '%d days' "$(( s / 86400 ))"; fi
}

# --- what the snapshot was taken ON TOP OF ------------------------------------
#
# wip_snapshot records the base commit in the snapshot's own message:
#
#   wip@artemis 2026-07-28T20:15:22-04:00 base=a1b2c3d branch=feat/x
#
# For a long time that field was WRITTEN AND NEVER READ, and the omission had
# teeth. A snapshot only exists because the other tree is dirty, but the other
# machine may ALSO have commits this one does not. `wip pull` then drops its
# files over this working tree while HEAD stays put, so every commit we are
# missing reappears as a huge pile of uncommitted changes on the wrong base --
# recoverable with `wip undo`, but exactly backwards. The reported diffstat is
# misleading in the same way: it compares two trees that are not comparable, so
# "+2000 −40" can be mostly commits `git pull` would have given for free.
#
# The answer is almost always BOTH, IN ORDER: `git pull` for the commits, then
# `wip pull` for the uncommitted work on top. These two functions are what lets
# the tool say so.

# The base commit recorded in a snapshot's subject line, or empty. A PURE
# parser over the subject wip_snapshot_meta already read -- it runs no git of
# its own, so adding the classification costs the cd-hook exactly one extra
# process (wip_base_state's `merge-base`) rather than two.
#
# Parameter expansion rather than sed/awk, for the same reason. `#* base=` is
# the SHORTEST match, so the leading `wip@<host> <date>` cannot hide a later
# literal " base=" -- and neither the ISO date nor a git branch name can contain
# a space, so the first one is always ours.
#
# The value is validated as plausible hex before any caller hands it to git. A
# hand-written or truncated message must read as "no base recorded" (which
# callers treat as "cannot classify, behave as before") rather than reaching
# `git merge-base` as an arbitrary string and coming back 128 -- i.e. being
# reported to the user as "the other machine has a commit you are missing" when
# in fact the message was simply malformed.
wip_snapshot_base() {
  local subject="$1" rest base
  case "$subject" in *" base="*) ;; *) return 0 ;; esac
  rest="${subject#* base=}"
  base="${rest%% *}"
  case "$base" in ''|*[!0-9a-fA-F]*) return 0 ;; esac
  # git's own minimum abbreviation. Shorter than this is not a commit-ish, it is
  # a corrupt message.
  [ "${#base}" -ge 4 ] || return 0
  printf '%s' "$base"
}

# Classify a snapshot's base against the LOCAL HEAD. Prints exactly one word:
#
#   ok       base is an ancestor of HEAD. We already have the commit the other
#            machine was sitting on, so `wip pull` is the whole answer.
#   ahead    base is an object we can see, but it is NOT in our history: the
#            other machine has commits we do not (typically we have fetched but
#            not merged). `git pull` first, then `wip pull`.
#   unknown  base names no object here at all -- we have not even fetched it,
#            or the other machine never pushed the commit. `git fetch` first.
#   none     no usable base= in the message, or git answered something no
#            documented exit status covers. Classification unavailable.
#
# The three exit statuses are `git merge-base --is-ancestor`'s own, measured
# directly rather than inferred: 0 = ancestor, 1 = not an ancestor, 128 = the
# argument is not a valid object name. Anything else maps to `none`, i.e. to
# the behaviour this tool had before the classifier existed -- an unexpected
# status must not turn `wip pull` into something that refuses everything.
#
# READ-ONLY against the user's repo, and that is a hard requirement, not a
# nicety: this runs on every `cd` through the fish hook. `merge-base` never
# refreshes or rewrites the index (unlike `git status`, which is why every
# `status` in this tool carries --no-optional-locks) and touches nothing under
# .git. tests/wip.test.sh pins that with a full content manifest of .git taken
# across a classifying wip_notice, and the mutation check for it is a plain
# `git status` in this function against a staled index -- which fails it.
#
# Two known imprecisions, both deliberately left, and both landing on the safe
# side (they can only make this refuse, never make it wave something through):
#
# 1. wip_snapshot writes `rev-parse --short`, and git's abbreviation length
#    scales with the OBJECT COUNT of the repo it ran in -- so a 7-character
#    prefix from artemis can be ambiguous in ariane's copy of the same project.
#    Verified against the live hub on 2026-07-28: most bases are 7 characters
#    but Tautulli's is 8. An ambiguous prefix exits 128, i.e. reports `unknown`
#    and asks for a `git fetch` that will not help. Writing the full 40-char sha
#    would remove this, at the cost of invalidating the format every snapshot
#    now on the hub carries; not worth it for a failure that is conservative.
# 2. If HEAD itself cannot be resolved (an unborn branch) merge-base also exits
#    128, so the user is told to `git fetch` when the real story is "this repo
#    has no commits".
wip_base_state() {
  local repo="$1" base="$2" rc=0
  [ -n "$base" ] || { printf 'none'; return 0; }
  git -C "$repo" merge-base --is-ancestor "$base" HEAD 2>/dev/null || rc=$?
  case "$rc" in
    0)   printf 'ok'      ;;
    1)   printf 'ahead'   ;;
    128) printf 'unknown' ;;
    *)   printf 'none'    ;;
  esac
}

# One-line summary for the current repo, or empty. Used by both `wip` and the
# fish cd-hook, so they can never disagree.
#
# Three distinct notices, because "there is a snapshot waiting" and "you can
# apply it" are different claims and only one of them used to be made. The
# diffstat is printed ONLY in the `ok` case: in the other two the two trees are
# not comparable, and a number that is mostly other people's commits is worse
# than no number at all.
#
# The classification happens AFTER the "is there anything to announce" gate, on
# purpose. This function runs on every `cd`, and the overwhelmingly common
# in-repo outcome is "nothing waiting", which returns above -- so the one extra
# git invocation is paid only on the `cd`s that actually print something.
# Measured on ariane, 100 runs of the `wip notice` process against a 120-file
# fixture: 16.41 -> 16.64 ms with nothing waiting, 48.87 -> 54.52 ms with a
# snapshot to announce.
wip_notice() {
  local repo="$1" slug shadow meta ts subject age stat other base state
  slug="$(wip_slug "$repo")"; shadow="$(wip_shadow "$slug")"
  [ -d "$shadow" ] || return 0
  # Hoisted: this used to be re-evaluated for the ref and again for the printf.
  other="$(wip_other_host)"
  meta="$(wip_snapshot_meta "$shadow" "$other")"
  [ -n "$meta" ] || return 0
  ts="${meta%%$'\n'*}"
  # A snapshot with an EMPTY subject yields a single line, and peeling past the
  # end of a string leaves it unchanged -- so `subject` would be the timestamp.
  # Harmless: it contains no " base=", so it parses as "no base recorded".
  subject="${meta#*$'\n'}"
  # Never do arithmetic on something that is not a number: a corrupt %ct would
  # otherwise be a shell error under `set -e`, or an absurd age. Same discipline
  # as wip_hub_last_age's guard on the hub-contact stamp.
  case "$ts" in ''|*[!0-9]*) return 0 ;; esac
  age=$(( $(date +%s) - ts ))
  stat="$(wip_shadow_diff "$repo" "refs/wip/$other" --shortstat 2>/dev/null)"
  [ -n "$stat" ] || return 0

  base="$(wip_snapshot_base "$subject")"
  state="$(wip_base_state "$repo" "$base")"
  case "$state" in
    ahead)
      printf '⬇  snapshot from %s · %s ago · based on %s, which is not in your history — run `git pull` first, then `wip pull`\n' \
        "$other" "$(wip_human_age "$age")" "$base" ;;
    unknown)
      printf '⬇  snapshot from %s · %s ago · base %s is unknown here — run `git fetch` first (%s may not have pushed it)\n' \
        "$other" "$(wip_human_age "$age")" "$base" "$other" ;;
    # `ok`, and `none` (an unreadable base= is not a reason to withhold the
    # notice this tool has always printed).
    *)
      printf '⬇  snapshot from %s · %s ago ·%s · run `wip pull`\n' \
        "$other" "$(wip_human_age "$age")" "$stat" ;;
  esac
}
