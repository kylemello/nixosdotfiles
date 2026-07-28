# Cross-machine environment sync: artemis ↔ ariane

**Date:** 2026-07-28
**Status:** Design approved, pending implementation plan

## Goal

Work on either machine and have the other catch up without thinking about it —
tooling, work-in-progress code, loose files, Claude configuration, and shell
history. Both machines stay real, independent machines; this is not a remote-dev
setup.

## Non-goals

- **Not** collapsing to a single remote environment (Coder / Codespaces / DevPod
  were considered and rejected — see "Rejected alternatives").
- **Not** syncing build artifacts. `node_modules`, `.venv`, `target`, `dist`,
  `.direnv` are arch-specific (artemis is x86_64 Linux, ariane is aarch64
  Darwin) and must be rebuilt per machine regardless.
- **Not** automatic application of uncommitted changes to a working tree.
  Landing a snapshot is always a deliberate action.
- **Not** replacing 1Password. Secrets management is unchanged.

## Current state

Measured 2026-07-28 on ariane:

| Fact | Value |
|---|---|
| Home Manager on ariane | generation 4, activated 2026-07-27 |
| Shared modules | `ariane.nix` and `home.nix` import the same `home/` set |
| Platform divergence | `home/wsl.nix` vs `home/darwin.nix` only |
| `~/work` + `~/personal` | 20.2 GB, 22 git repos |
| Excludable build dirs | 13.0 GB across 594,196 files |
| `.git` directories | 0.5 GB |
| Actual payload | ~7 GB |
| gateway | Proxmox VM, reachable at 4 ms, SSH key auth working, 24/7 |
| Tailscale | Company tailnet; `kyles-windows-desktop` present, frequently offline |

The config layer is already unified. The gap is everything that is not config.

## Architecture

```
   artemis (WSL, x86_64)                        ariane (macOS, aarch64)
   home desktop                                 work laptop
        │                                              │
        │              ┌────────────────────┐          │
        └─────────────▶│      gateway       │◀─────────┘
                       │  Proxmox VM, 24/7  │
                       │  ────────────────  │
                       │  /home/kyle/wip/   │  bare snapshot repos
                       │  syncthing         │  ~/notes, ~/scratch
                       │  atuin server      │  shell history
                       └────────────────────┘
```

gateway is the hub so neither endpoint depends on the other being awake. It is
already NixOS and already in the flake, so it is declared the same way as
everything else.

| Layer | Mechanism | New code |
|---|---|---|
| Config | Nix flake (existing) + drift alarm | small |
| Repos | `wip` script → bare repos on gateway | ~80 lines shell |
| Loose files | Syncthing via gateway | ~4 lines |
| Claude state | flake repo, live symlinks | small |
| Shell history | Atuin server on gateway, fzf front-end | small |
| Secrets | 1Password (unchanged) | none |

---

## Layer 1 — Config drift

Both profiles already import the same modules. The missing piece is a signal
that one machine has not rebuilt.

The 5-minute timer (Layer 2) also runs `git -C ~/nixosdotfiles fetch`. Fish then
warns at shell start if the repo has moved since the last `home-manager switch`,
comparing `git rev-parse HEAD` against a marker written at activation time. The
hot path is a local git read plus a file read — no network.

```
⚠  nixosdotfiles is 3 commits behind your last switch — run ./update.sh
```

---

## Layer 2 — Repos, via `wip`

### Constraint

The user's repos must not be modified. No added remotes, no added refs, nothing
visible in `git remote -v`, `git branch`, `git log --all`, or lazygit.

### Snapshot (push side)

```sh
tmp=$(mktemp)
GIT_INDEX_FILE=$tmp git read-tree HEAD
GIT_INDEX_FILE=$tmp git add -A
tree=$(GIT_INDEX_FILE=$tmp git write-tree)
sha=$(git commit-tree "$tree" \
      -m "wip@artemis $(date -Iseconds) base=$(git rev-parse --short HEAD) branch=$(git branch --show-current)")
git push --force "ssh://gateway/home/kyle/wip/${slug}.git" "$sha:refs/heads/wip/artemis"
```

Properties:

- **Temp index.** The real `.git/index` is never touched, so the operation
  cannot collide with an in-flight git command.
- **Parentless commit.** No history is transferred to gateway, and the snapshot
  is self-contained. Base commit and branch are recorded in the message instead.
- **Push by URL.** `.git/config` is never modified.
- **`.gitignore` does the exclusion.** `git add -A` already skips the 13 GB /
  594k files, because every repo already declares them ignored. There is no
  separate ignore list to maintain, and it is correct in every repo
  automatically. This is the single strongest reason for this approach over a
  file-sync tool.
- **Idempotent.** Skipped when the computed tree SHA matches the last push, so
  an idle repo costs one `write-tree` and no network.

Residual trace: `git add -A` writes blobs to the object store. They are
unreachable from any ref, invisible to every git command, and pruned by routine
`git gc`.

### Receive side — shadow repo

Snapshots are fetched into `~/.cache/wip/<slug>.git`, never the real repo:

```sh
git --git-dir="$HOME/.cache/wip/${slug}.git" fetch "$url" 'refs/heads/wip/*:refs/wip/*'
git --git-dir="$HOME/.cache/wip/${slug}.git" --work-tree="$repo" diff refs/wip/artemis
```

Splitting `--git-dir` from `--work-tree` lets the snapshot metadata live in the
cache while diffing against the real files. The work repo gains zero refs, so
`git log --all` stays clean and `git push --mirror` has nothing to leak.

Because the snapshot commit is parentless, the shadow repo only ever holds
snapshot trees and blobs — never commit history.

### CLI

Every verb derives its repo from `$PWD`. No repo argument, ever. No host
argument — there are two machines, so "the other one" is unambiguous.

```
wip           in a repo  → what's waiting here, from where, how stale
              elsewhere  → every repo with a pending snapshot
wip pull      land the newest snapshot from the other host
wip diff      snapshot vs working tree
wip push      snapshot now (the timer does this anyway)
```

`wip` prints the next command to run, so `wip` is the only verb that must be
remembered.

### Passive notification

A fish `--on-variable PWD` hook prints one line on entering a repo that has a
newer snapshot from the other host, and is silent otherwise:

```
⬇  snapshot from artemis · 14 min ago · 3 files, +47 −12 · run `wip pull`
```

The check is two local ref reads in the shadow repo — no SSH, works offline.
Trigger condition: `refs/wip/<other-host>` exists and is newer than
`refs/wip/<this-host>`. Suppressed after `wip pull` via an ack ref.

### Timer

Every 5 minutes, `systemd.user.timers` on artemis and `launchd.agents` on
ariane, both generated from `home/wip.nix`:

1. Push snapshots for dirty repos under the enabled roots.
2. Fetch the other host's snapshots into the shadow repos.
3. Fetch `nixosdotfiles` for the drift alarm.

### `wip pull` semantics

Fetches and shows the diff. Does **not** modify the working tree without
explicit confirmation. Refuses on a dirty tree unless `--force`. This is
deliberate: auto-materializing uncommitted changes over a tree that has its own
edits is how work gets lost.

### Host identity

Baked in at build time (`host = "artemis"` in `home/wsl.nix`, `"ariane"` in
`home/darwin.nix`) rather than read from `hostname` at runtime — ariane's actual
hostname is `kyles-macbook-pro`, which would produce confusing ref names.

---

## Layer 3 — Loose files

Syncthing via gateway, scoped to `~/notes` and `~/scratch` only. No `.git`
directories, a few hundred MB, genuinely ambient. Staggered file versioning on
gateway doubles as a rolling backup.

Repos deliberately do **not** go through Syncthing — that is Layer 2's job, and
keeping `.git` out of the sync set removes the lock-file hazard entirely.

---

## Layer 4 — Claude state

`~/.claude/{CLAUDE.md,skills,agents,commands}` become
`config.lib.file.mkOutOfStoreSymlink` targets pointing into
`nixosdotfiles/claude/`. They stay writable, edits take effect immediately, and
they are versioned in git — strictly better than file-sync for content that is
edited deliberately.

**Synced:** `CLAUDE.md`, `skills/`, `agents/`, `commands/`

**Never synced:** `settings.json` (Claude Code rewrites it itself),
`projects/`, `history.jsonl`, `.credentials.json`, `cache/`, `daemon/`,
`session-env/`, `shell-snapshots/`, `telemetry/`, `file-history/`, `backups/`

---

## Layer 5 — Shell history

`services.atuin` on gateway; clients on both machines pointed at it rather than
`api.atuin.sh`.

### fzf front-end (required)

The user's `Ctrl+R` must keep the `fzf.fish` interface — only the data source
changes. `fzf.fish` provides six widgets; Atuin collides with exactly one:

| Widget | Bind | Conflict |
|---|---|---|
| Search Directory | `Ctrl+Alt+F`, plus user-bound `Ctrl+T` | No |
| **Search History** | **`Ctrl+R`** | **Yes** |
| Search Git Log | `Ctrl+Alt+L` | No |
| Search Git Status | `Ctrl+Alt+S` | No |
| Search Variables | `Ctrl+V` | No |
| Search Processes | `Ctrl+Alt+P` | No |

Atuin's own keybinding is disabled:

```nix
programs.atuin = {
  enable = true;
  flags = [ "--disable-ctrl-r" "--disable-up-arrow" ];
  settings = {
    search_mode  = "fuzzy";        # module example defaults to "prefix" — do not inherit it
    filter_mode  = "global";
    sync_address = "http://gateway:8888";
  };
};
```

`Ctrl+R` is then bound to a clone of `_fzf_search_history` with only the data
source swapped. The upstream function's flags are preserved verbatim so the
interface is unchanged:

```fish
function _fzf_atuin_history --description "Search Atuin history with the fzf.fish interface"
    set -f time_prefix_regex '^.*? │ '
    set -f commands_selected (
        atuin search --print0 --limit 10000 --format "{time} │ {command}" |
        _fzf_wrapper --read0 \
            --print0 \
            --multi \
            --scheme=history \
            --prompt="History> " \
            --query=(commandline) \
            --preview="string replace --regex '$time_prefix_regex' '' -- {} | fish_indent --ansi" \
            --preview-window="bottom:3:wrap" \
            $fzf_history_opts |
        string split0 |
        string replace --regex $time_prefix_regex ''
    )
    if test $status -eq 0
        commandline --replace -- $commands_selected
    end
    commandline --function repaint
end

bind \cr _fzf_atuin_history
bind -M insert \cr _fzf_atuin_history
```

Preserved from upstream: `_fzf_wrapper` (so `SHELL` and `FZF_DEFAULT_OPTS`
behave identically), `--multi`, `--scheme=history`, the `History> ` prompt, the
`fish_indent --ansi` preview, the U+2502 separator, and the `$fzf_history_opts`
user extension variable.

Dropped: `builtin history merge` (not applicable to Atuin).

Verified against the packaged binary (`atuin 18.17.1`, aarch64-darwin):
`--print0`, `--format` with `{time}`/`{command}`, `--limit`, `--reverse`,
`--filter-mode`, and dedup-by-default (`--include-duplicates` opts out) all
exist.

**Known cosmetic delta:** `fzf.fish` renders timestamps as `%m-%d %H:%M:%S`.
Atuin's `{time}` rendering is not controlled by a CLI flag and may differ in
width. Resolutions, in preference order: (a) accept Atuin's format, (b)
post-process the timestamp column with `string replace` before it reaches fzf.
Decide at implementation time by looking at the actual output.

**To verify at implementation:** whether Atuin's `--print0` is a record
*separator* or only a trailing terminator. `fzf --read0` requires the former.

**Ordering caveat:** `home/fish.nix` calls `fish_vi_key_bindings` *after* its
`bind` lines. Where Home Manager injects the Atuin init hook relative to that
call determines whether the binds survive in vi mode. Not a blocker; expect to
nudge the ordering.

---

## Layer 6 — Secrets

Unchanged. 1Password on both machines, `op-ssh-sign` already wired per platform
in `home/wsl.nix` and `home/darwin.nix`.

---

## Gateway changes

### Hub services

- `services.syncthing` — declarative folders and devices for `~/notes`,
  `~/scratch`, with staggered versioning.
- `services.atuin` — history server, bound to the tailnet/LAN interface.
- `systemd.tmpfiles` — `/home/kyle/wip` at mode `0700`, owner `kyle`.

### CI hardening

`machines/gateway/configuration.nix` currently sets:

```nix
workDir = "/home/ci/actions-runner";
serviceOverrides.ProtectHome = false;
```

As the existing in-file comment notes, this exposes `/home/kyle` and
`/home/seth` to CI jobs. The runner is `enable = false` today, but snapshots
will live under `/home/kyle`, so this is fixed as part of this work:

```nix
workDir = "/var/lib/ci-runner/work";
# ProtectHome override removed — back to the module default (true)
```

`/home` is then fully masked from CI jobs. Consequential edits:

- `systemd.tmpfiles.rules`: `d /var/lib/ci-runner/work 2770 ci ci -`
  (replaces the `/home/ci/actions-runner` rule).
- `users.users.ci.homeMode = "0750"` is dropped — it existed only to let the
  `ci` group traverse into `/home/ci`, which is no longer where the workspace
  lives. Reverts to the `0700` default.
- Seth retains access: still in the `ci` group, the workspace is still setgid
  `2770 ci ci`, and `ProtectHome` does not affect `/var/lib`.
- `tokenFile = "/var/lib/ci-runner/github-token"` is unaffected.

This returns the runner to the NixOS module's supported default rather than
inventing a new configuration.

`/home/kyle` is already mode `0700` under NixOS defaults, and Seth has no sudo,
so snapshots are unreadable by other accounts.

---

## Configuration surface

```nix
kyle.wip = {
  enable   = true;
  host     = "artemis";              # baked at build time
  roots    = [ "personal" "work" ];  # drop "work" to keep BRR code off the homelab
  remote   = "ssh://gateway/home/kyle/wip";
  interval = 5;                      # minutes
};

kyle.sync.folders = [ "notes" "scratch" ];
```

`roots` is independently toggleable so the decision about whether BRR work
repos land on the homelab is a one-line change, not a redesign.

---

## File change map

**New**

| Path | Purpose |
|---|---|
| `home/wip.nix` | `wip` script, timer (systemd/launchd), fish cd-hook, module options |
| `home/sync.nix` | Syncthing client for `~/notes`, `~/scratch` |
| `home/atuin.nix` | Atuin client + `_fzf_atuin_history` + `Ctrl+R` bind |
| `home/claude.nix` | `mkOutOfStoreSymlink`s for `~/.claude/*` |
| `hosts/sync-hub.nix` | gateway: syncthing, atuin server, `/home/kyle/wip` |
| `claude/` | `CLAUDE.md`, `skills/`, `agents/`, `commands/` moved into the repo |

**Modified**

| Path | Change |
|---|---|
| `home/folders.nix` | Canonical layout: `~/personal ~/work ~/notes ~/scratch` |
| `home/wsl.nix` | Windows-backed links (artemis-only); `wip.host = "artemis"` |
| `home/darwin.nix` | `wip.host = "ariane"` |
| `home/fish.nix` | Binding-order adjustment for Atuin/vi-mode |
| `users/kyle/home.nix` | Import new modules |
| `users/kyle/ariane.nix` | Import new modules |
| `machines/gateway/configuration.nix` | Import `sync-hub`; CI hardening |

Helper scripts use `writeShellScriptBin`, not `writeShellApplication`, per
`CLAUDE.md` (the latter pulls in shellcheck, a heavy Haskell build).

New files must be `git add`ed before evaluation — flakes only see tracked files.

---

## Rejected alternatives

| Option | Why not |
|---|---|
| **Syncthing for repos** | Requires a hand-maintained `.stignore` duplicating what `.gitignore` already says, in 22 repos, kept in step forever. Also replicates `.git/*.lock`, which blocks git on the receiving machine. |
| **Mutagen** | Better than Syncthing for code (git-native ignores, SSH transport, halts on conflict). Made obsolete by the `wip` design, which gets `.gitignore` semantics for free and needs no ignore config at all. |
| **`wip` remotes via `git remote add`** | Pollutes `git remote -v` in every repo and needs per-repo setup. Push-by-URL achieves the same with zero repo modification. |
| **`commit-tree -p HEAD`** | Chains snapshots onto real history, forcing the shadow repo to hold full history and sending commit history to gateway. Parentless commits avoid both. |
| **`refs/wip/*` in the real repo** | Faster and simpler, but the refs appear in `git log --all` and would be pushed by `git push --mirror`. Rejected on the explicit requirement that work repos stay pristine. |
| **Coder / Codespaces / Gitpod / DevPod** | Solve the problem by deleting the second machine. Coder is viable on the existing Proxmox cluster but is built for teams of 10+; Codespaces/Gitpod would place BRR code with a third party. Rejected — both machines stay real. |
| **Daytona** | Pivoted to AI agent sandboxes; no longer addresses this. |
| **Flox / chezmoi** | Overlap what the flake and Home Manager already do — there is nothing left for a second dotfile manager to own. |
| **Auto-applying snapshots** | Silently overwriting a working tree that has its own edits loses work. |

---

## Risks

| Risk | Mitigation |
|---|---|
| First run pushes large working trees | One-time; bounded by ~7 GB total and only for dirty repos |
| gateway unreachable | Push is skipped and retried next tick; `wip pull` works offline from the shadow cache |
| Snapshot from the other host is stale/unwanted | `wip diff` before `wip pull`; pull never auto-applies |
| Shadow cache grows | Bounded by snapshot trees only (no history); prune ref older than N days in the timer |
| BRR code on the homelab | `roots` toggle; `/home/kyle/wip` at `0700`; CI hardening lands in the same change |
| Atuin `Ctrl+R` feels wrong | `search_mode = "fuzzy"` set explicitly; the fzf front-end preserves the existing interface |

---

## Pre-implementation verification

1. **gateway reachability from ariane off the home network.** It answered at
   4 ms during design, but `gateway.lan.kmello.dev` resolves through pfsense
   DNS to `10.11.12.105` — it is unconfirmed whether that is a tailnet subnet
   route or plain LAN. If LAN-only, gateway needs `services.tailscale.enable`.
2. **Atuin `--print0` semantics** — record separator vs trailing terminator.
3. **Atuin `{time}` rendering width** vs `fzf.fish`'s `%m-%d %H:%M:%S`.
4. **Atuin server registration** — each client needs a one-time key; not
   something Nix can do.
5. **Inventory artemis's WSL→Windows symlinks** once the desktop is awake, to
   populate the artemis-only section of `home/folders.nix`.

## Success criteria

- Editing a file on artemis, then `cd`-ing to that repo on ariane within ~5
  minutes, produces the `⬇ snapshot` line without any command being run.
- `git remote -v`, `git branch -a`, and `git log --all` in any work repo are
  byte-identical before and after the system is installed.
- `Ctrl+R` on both machines shows the `fzf.fish` interface, populated with
  commands run on the other machine.
- A package added to `home/packages/*.nix` on one machine produces the drift
  warning on the other.
- CI jobs on gateway cannot read `/home/kyle` or `/home/seth`.
- No ignore list anywhere duplicates `.gitignore`.
