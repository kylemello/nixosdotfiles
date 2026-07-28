# Cross-Machine Environment Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make artemis (NixOS on WSL) and ariane (macOS) feel like one environment — uncommitted work, loose files, Claude config, and shell history all follow you — with gateway as an always-on hub.

**Architecture:** Five independent layers over one hub. Nix already handles config. A `wip` shell tool snapshots dirty working trees to bare repos on gateway without modifying the source repo. Syncthing carries loose files. Atuin carries shell history behind the existing fzf interface. Claude config becomes live symlinks out of the flake.

**Tech Stack:** Nix flakes, Home Manager (NixOS module + standalone darwin), NixOS modules, bash, fish, git plumbing (`commit-tree`, `write-tree`, `read-tree`), Syncthing, Atuin.

**Spec:** `docs/superpowers/specs/2026-07-28-cross-machine-environment-sync-design.md`

## Global Constraints

- **Never modify the user's git repos.** No added remotes, no added refs, no touched HEAD/index/worktree. This is the hard requirement the whole `wip` design exists to satisfy. Task 3's test suite enforces it.
- **Run the `wip` tests under `nix shell nixpkgs#coreutils nixpkgs#git -c ...`**, never bare. `wip.sh` uses `date -Iseconds`, unsupported by BSD date on ariane.
- **No test/lint suite exists in this repo.** Verification for Nix changes is `nix eval` of a derivation path. `wip` gets a real bash test suite because it is real code.
- **`writeShellScriptBin`, never `writeShellApplication`** — the latter pulls in shellcheck, a heavy often-uncached Haskell build. Set `PATH` and `set -euo pipefail` manually.
- **Flakes only see git-tracked files.** `git add` every new file before running `nix eval`, or it will not be found.
- **`homeConfigurations` lives under `legacyPackages.<system>`**, not at the flake root. Verification commands must use the full path.
- **Host identity is baked at build time**, never read from `hostname`. ariane's real hostname is `kyles-macbook-pro`.
- **Slugs derive from the normalized `origin` URL**, never the directory name. The same project has different directory names on each machine (`DocResolve-brrit-com` vs `DocResolve-brrit.com`, `Census.Navigator.Mobile` vs `CensusNavigator`).
- **artemis login shell is fish.** Any `ssh artemis '<command>'` in testing must use `ssh artemis "bash -lc '...'"`.
- **artemis cannot sign commits or reach GitHub from a non-interactive SSH
  session.** Its git signs via `op-ssh-sign.exe` on the Windows host, and both
  that and `git@github.com` need the 1Password agent socket, which is absent over
  `ssh artemis '...'`. Consequences for every task that commits:
    - Commit on **ariane** wherever the change is platform-neutral.
    - If you must commit on artemis, use `--no-gpg-sign`, then re-sign from ariane
      with `git rebase --exec 'git commit --amend --no-edit -S' <base>`. A plain
      `git rebase` on artemis silently unsigns every replayed commit, including
      ones that were signed before.
    - artemis cannot `git fetch`/`push` GitHub non-interactively. Move refs with
      `git push ssh://artemis/home/kyle/nixosdotfiles master:refs/remotes/origin/master`
      from ariane, then `git reset --hard refs/remotes/origin/master` on artemis.
    - `git log --format=%G?` reports `N` for **every** commit here because
      `gpg.ssh.allowedSignersFile` is unset. That means "cannot verify", not
      "unsigned" — check with `git cat-file commit <sha> | grep '^gpgsig'`.
- **`python3` is not on artemis's non-interactive PATH.** Use `jq` (it is in
  `home/packages/base.nix`).
- **`nixpkgs` is unstable, `allowUnfree` is on.**

### Verification commands

```bash
# NixOS host (gateway, artemis)
nix eval .#nixosConfigurations.gateway.config.system.build.toplevel.drvPath
nix eval .#nixosConfigurations.artemis.config.system.build.toplevel.drvPath

# Standalone Home Manager (ariane, aarch64-darwin)
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
```

### Verified environment facts

Confirmed on 2026-07-28; do not re-derive.

| Fact | Value |
|---|---|
| NixOS `services.atuin` options | `database` `enable` `environmentFile` `host` `maxHistoryLength` `openFirewall` `openRegistration` `package` `path` `port` |
| NixOS `services.syncthing` | exists |
| HM `services.syncthing` on darwin | supported — module has both `systemd.user.services` and `launchd.agents` branches; only `.tray` is Linux-only |
| HM `services.syncthing` options | `allProxy` `cert` `enable` `extraOptions` `guiAddress` `guiCredentials` `key` `overrideDevices` `overrideFolders` `package` `passwordFile` `settings` `tray` |
| HM `programs.atuin` | exists; `flags` = "Flags to append to the shell hook" |
| HM `launchd.agents.<name>.config` | raw launchd plist keys (`ProgramArguments`, `StartInterval`, …) |
| HM `config.lib.file.mkOutOfStoreSymlink` | exists |
| `atuin` version | 18.17.1 |
| `atuin init fish` flags | `--disable-ctrl-r` `--disable-up-arrow` `--disable-ai` |
| `atuin search` flags | `--print0` `--format` `--limit` `--reverse` `--filter-mode` `--cwd`; dedups unless `--include-duplicates` |
| gateway capacity | 62 G disk / 31 G free, 11 G RAM, ports 8384 / 8888 / 22000 free |
| artemis repos | 37 under `~/work` + `~/personal` (4.9 G + 3.1 G) |
| ariane repos | 22 under `~/work` + `~/personal` (17 G + 3.2 G) |
| `~/work/work-knowledge-repo` (artemis) | git repo, symlink → `/mnt/c/Users/kylem/Vaults/…` on 9p. Must be excluded. |
| artemis Windows symlinks | `~/.aws` `~/.azure` `~/.docker/contexts` `~/.docker/features.json` → `/mnt/c/Users/kylem/…` |

---

## File Structure

**New**

| Path | Responsibility |
|---|---|
| `hosts/sync-hub.nix` | gateway-only: atuin server, syncthing server, `/home/kyle/wip` storage |
| `home/wip.nix` | `kyle.wip` options; packages the `wip` script; timer; fish hook |
| `home/wip/wip.sh` | The `wip` implementation (sourced into `writeShellScriptBin`) |
| `home/atuin.nix` | Atuin client + `_fzf_atuin_history` + `Ctrl+R` binding |
| `home/claude.nix` | `mkOutOfStoreSymlink`s for `~/.claude/*` |
| `home/sync.nix` | Syncthing client for `~/notes`, `~/scratch` |
| `home/drift.nix` | Flake-staleness warning at shell start |
| `claude/` | `CLAUDE.md`, `skills/`, `agents/`, `commands/`, `settings.json` (shared) |
| `claude/local/<host>.json` | per-machine settings: absolute marketplace paths |
| `tests/wip.test.sh` | Bash test suite for the `wip` snapshot core |

**Modified**

| Path | Change |
|---|---|
| `machines/gateway/configuration.nix` | Import `sync-hub`; CI hardening |
| `home/folders.nix` | Canonical layout; artemis-only Windows links |
| `home/wsl.nix` | `kyle.wip.host` / `kyle.claude.host` = `"artemis"`; Windows links |
| `home/darwin.nix` | `kyle.wip.host` / `kyle.claude.host` = `"ariane"` |
| `home/fish.nix` | Binding order for Atuin under vi mode; `q` function from artemis |
| `users/kyle/home.nix` | Import new modules |
| `users/kyle/ariane.nix` | Import new modules |

---

# Phase 0 — Escape hatch

**Status: COMPLETE (2026-07-28).** Recorded here as the undo runbook.

The goal is a restart point, not a backup regime. Most of what this project
touches is already reversible: the flake is git, Nix keeps generations, and the
repos are never written to. What follows is the small remainder.

## Restore points

| Machine | State at baseline | Undo |
|---|---|---|
| flake repo | tag **`pre-sync`** → `df21304` (docs only; nothing functional had landed) | `git reset --hard pre-sync` |
| ariane | HM generation **4** (2026-07-27 23:50) | `home-manager switch --rollback` |
| artemis | system generation **152** (HM included — it uses the NixOS module) | `nixos-rebuild switch --rollback` |
| gateway | system generation **13**, VMID **101** on **zarya** | rollback to 13 — no VM snapshot taken, gateway is disposable |

## Archived off-machine

`truenas_admin@truenas:~/escape-hatch/` — verified 2026-07-28, checksums matched
source byte-for-byte and both archives list cleanly.

| File | Size | SHA-256 | Entries |
|---|---|---|---|
| `claude-ariane.tgz` | 21 M | `a970b6e0…2c9261c1` | 3598 |
| `claude-artemis.tgz` | 68 M | `a71e4b2a…09720b4a` | 3925 |

`/home/truenas_admin` is on **boot-pool**, which TrueNAS wipes on major
upgrades. Fine for a days-long escape hatch, not for archival. The pool
datasets under `/mnt/Infinity` need a sudo password.

## What needs no undo

- **The repos.** Nothing in this system writes to them. `wip_snapshot` builds
  its tree through a temp index and pushes by URL; Task 3's suite asserts
  `remote -v`, `branch -a`, `for-each-ref`, `HEAD`, `status` and the byte-hash
  of `.git/index` are unchanged. The single exception is `wip pull`, which is
  why Task 5 carries a safety ref.
- **`~/notes`, `~/scratch`, `~/.cache/wip`, `~/.local/state/wip`** — all newly
  created. `rm -rf` is a complete undo.
- **Syncthing** — Task 9 creates the folders empty. There is nothing in them to
  delete, so the delete-propagation footgun cannot fire.

## Full undo

```bash
git -C ~/nixosdotfiles reset --hard pre-sync
home-manager switch --flake .#ariane                          # ariane
ssh artemis "bash -lc 'sudo nixos-rebuild switch --flake ~/nixosdotfiles#artemis'"
ssh gateway "bash -lc 'sudo nixos-rebuild switch --flake ~/nixosdotfiles#gateway'"
rm -rf ~/notes ~/scratch ~/.cache/wip ~/.local/state/wip
# only if Task 11 ran:
scp truenas_admin@truenas:~/escape-hatch/claude-ariane.tgz /tmp/
rm -rf ~/.claude && tar xzf /tmp/claude-ariane.tgz -C ~
```

## Out of scope, but standing

**artemis has no backup of any kind.** Its 8 G of `~/work` + `~/personal` lives
in a WSL vhdx that nothing captures. This plan does not endanger it — nothing
writes to those repos — but the exposure predates this work and outlives it.
ariane is covered by Time Machine to `Infinity/mac_time_machine` (839 G stored,
and `~/work`, `~/personal`, `~/.claude`, `~/nixosdotfiles` are all Included).

---

# Phase 1 — Gateway hub

Everything else depends on this. Phase 1 is a safe stopping point: it produces a working hub with nothing pointed at it yet.

## Task 1: Harden gateway CI so `/home` is unreachable

**Files:**
- Modify: `machines/gateway/configuration.nix:80-82` (tmpfiles rule), `:104-122` (runner block), `:67-75` (ci user)

**Interfaces:**
- Consumes: nothing
- Produces: `/home/kyle` is safe for `wip` storage in Task 2

**Why:** The runner currently sets `serviceOverrides.ProtectHome = false` so its workDir under `/home/ci` is reachable. The in-file comment already flags that this exposes `/home/kyle` and `/home/seth`. Task 2 puts snapshots under `/home/kyle`, so this must land first. The fix returns the runner to the NixOS module's default rather than inventing a new configuration.

- [ ] **Step 1: Move the runner workspace out of `/home`**

In `machines/gateway/configuration.nix`, replace the tmpfiles rule:

```nix
  # Runner workspace outside /home so ProtectHome can stay on. setgid (2770)
  # so files the runner creates are group-owned by `ci`, letting seth read and
  # write build artifacts. The runner wipes this dir's *contents* on start.
  systemd.tmpfiles.rules = [
    "d /var/lib/ci-runner/work 2770 ci ci -"
  ];
```

- [ ] **Step 2: Point the runner at it and drop the ProtectHome override**

Replace `workDir` and delete the `serviceOverrides` line and its comment block:

```nix
    workDir = "/var/lib/ci-runner/work";
    extraLabels = [ "gateway" "nixos" ];
    extraPackages = with pkgs; [ git docker ];

    # ProtectHome is left at the module default (true), so CI jobs cannot read
    # /home/kyle or /home/seth. The workspace lives under /var/lib, which
    # ProtectHome does not mask. Seth still reaches it via the `ci` group.
  };
```

- [ ] **Step 3: Drop the now-unneeded homeMode override**

`users.users.ci.homeMode = "0750"` existed only to let the `ci` group traverse into `/home/ci`. The workspace no longer lives there. Remove the line and its comment, leaving:

```nix
  users.groups.ci = {};
  users.users.ci = {
    isNormalUser = true;
    description = "CI runner service account";
    shell = pkgs.bash;
    group = "ci";
    extraGroups = [ "docker" ];
  };
```

- [ ] **Step 4: Verify it evaluates**

```bash
nix eval .#nixosConfigurations.gateway.config.system.build.toplevel.drvPath
```
Expected: a `/nix/store/...drv` path, no errors.

- [ ] **Step 5: Assert ProtectHome is actually on**

The runner is `enable = false`, so **no `github-runner-gateway` unit is generated**
and reading it directly fails with "does not provide attribute" — verified, the
filtered service list comes back `[ ]`. Probe a force-enabled copy of the config
instead, which exercises the real generated unit:

```bash
nix eval --impure --expr '
  let
    f = builtins.getFlake (toString ./.);
    probe = f.nixosConfigurations.gateway.extendModules {
      modules = [({ lib, ... }: { services.github-runners.gateway.enable = lib.mkForce true; })];
    };
  in probe.config.systemd.services.github-runner-gateway.serviceConfig.ProtectHome
'
```
Expected: `true`. **Before this task it returns `false`** (measured 2026-07-28), so
this is a genuine before/after check rather than a tautology. `lib.mkForce` is
required — a plain `enable = true` collides with the config's `false` at equal
priority and errors on the option, not on ProtectHome.

Also confirm the workDir moved. Option values (unlike generated units) exist even
when the service is disabled:

```bash
nix eval --raw .#nixosConfigurations.gateway.config.services.github-runners.gateway.workDir
```
Expected: `/var/lib/ci-runner/work`. Before this task it is `/home/ci/actions-runner`.

- [ ] **Step 6: Commit**

```bash
git add machines/gateway/configuration.nix
git commit -m "gateway: keep ProtectHome on, move CI workspace to /var/lib

The runner's workDir lived under /home/ci, which required
serviceOverrides.ProtectHome = false and exposed /home/kyle and
/home/seth to CI jobs. Move the workspace to /var/lib/ci-runner/work so
the module default (ProtectHome = true) applies. Seth keeps access via
the setgid ci group, which ProtectHome does not affect."
```

---

## Task 2: Stand up the hub services on gateway

**Files:**
- Create: `hosts/sync-hub.nix`
- Modify: `machines/gateway/configuration.nix` (imports)

**Interfaces:**
- Consumes: Task 1's hardened `/home`
- Produces: `/home/kyle/wip` (0700) for Task 4's bare repos; Atuin server on `:8888`; Syncthing on `:8384`/`:22000` for Task 12

- [ ] **Step 1: Write the hub module**

Create `hosts/sync-hub.nix`:

```nix
{ config, lib, pkgs, ... }:

# Always-on sync hub. Imported only by gateway. Both endpoints (artemis,
# ariane) talk to this box rather than to each other, so neither has to be
# awake for the other to catch up.
{
  # --- wip snapshot storage --------------------------------------------------
  # Bare repos created on demand by the `wip` script over SSH (home/wip.nix).
  # 0700 under kyle's home: unreadable by seth (no sudo) and by CI jobs
  # (ProtectHome masks /home entirely — see machines/gateway/configuration.nix).
  systemd.tmpfiles.rules = [
    "d /home/kyle/wip 0700 kyle users -"
    "d /home/kyle/wip/_manifest 0700 kyle users -"
    # The Syncthing folder paths below. Home Manager creates these on the
    # clients (home/folders.nix, Task 9) and gateway does import
    # users/kyle/home.nix, but that lands in a later task — declaring them here
    # means Syncthing never starts against a missing path.
    "d /home/kyle/notes 0755 kyle users -"
    "d /home/kyle/scratch 0755 kyle users -"
  ];

  # --- Atuin: shell history server ------------------------------------------
  # Clients point here instead of api.atuin.sh (home/atuin.nix).
  services.atuin = {
    enable = true;
    host = "0.0.0.0";
    port = 8888;
    # Registration is opened for the initial `atuin register` on each machine,
    # then should be flipped to false and rebuilt. Two clients, one user.
    openRegistration = true;
    openFirewall = true;
  };

  # GUI port. openDefaultPorts does not cover it (see the comment on
  # guiPasswordFile below), so it is opened explicitly.
  networking.firewall.allowedTCPPorts = [ 8384 ];

  # --- Syncthing: loose files ------------------------------------------------
  # Scope is deliberately small: ~/notes and ~/scratch only. Repos go through
  # `wip`, config goes through the flake.
  services.syncthing = {
    enable = true;
    user = "kyle";
    group = "users";
    dataDir = "/home/kyle";
    configDir = "/home/kyle/.config/syncthing";
    guiAddress = "0.0.0.0:8384";
    openDefaultPorts = true;

    # openDefaultPorts covers ONLY 22000/tcp+udp and 21027/udp — it does not
    # open the GUI port, so binding 0.0.0.0 above achieves nothing without this.
    # And because gateway has a second human user (seth, SSH shell, no sudo),
    # a non-loopback GUI bind must be authenticated: nixpkgs has no assertion
    # forcing that, so an unauthenticated control plane would otherwise be
    # reachable by him over loopback and by anyone on the LAN/Teleport once the
    # port is open. Create the password file on gateway, NOT in git. It must be
    # owned by the syncthing user (kyle) -- syncthing-init runs as that user, and
    # a root-owned 0400 file makes merge-syncthing-config fail with
    # "Permission denied" and silently leave no <password> element at all:
    #   head -c 18 /dev/urandom | base64 | sudo tee /var/lib/syncthing/gui-password >/dev/null
    #   sudo chown kyle:users /var/lib/syncthing/gui-password
    #   sudo chmod 400 /var/lib/syncthing/gui-password
    guiPasswordFile = "/var/lib/syncthing/gui-password";
    settings.gui.user = "kyle";

    settings = {
      options.urAccepted = -1; # decline usage reporting

      folders = {
        "notes" = {
          path = "/home/kyle/notes";
          devices = [ "artemis" "ariane" ];
          versioning = {
            type = "staggered";
            params.maxAge = "2592000"; # 30 days, in seconds
          };
        };
        "scratch" = {
          path = "/home/kyle/scratch";
          devices = [ "artemis" "ariane" ];
          versioning = {
            type = "staggered";
            params.maxAge = "604800"; # 7 days
          };
        };
      };
    };
  };
}
```

- [ ] **Step 2: Import it into gateway**

In `machines/gateway/configuration.nix`, extend the imports list:

```nix
  imports = [
    ./hardware-configuration.nix
    ../../hosts/common.nix
    ../../hosts/sync-hub.nix
  ];
```

- [ ] **Step 3: Track the new file and verify**

```bash
git add hosts/sync-hub.nix
nix eval .#nixosConfigurations.gateway.config.system.build.toplevel.drvPath
```
Expected: a store path. A `device ... not found` error here means the Syncthing device IDs are not yet declared — that is expected and resolved in Task 12. If it blocks, temporarily comment out the `devices` lines and restore them in Task 12.

- [ ] **Step 4: Deploy and confirm the services are live**

```bash
ssh gateway "bash -lc 'sudo nixos-rebuild switch --flake /home/kyle/nixosdotfiles#gateway'"
ssh gateway "bash -lc 'systemctl is-active atuin syncthing; ls -ld /home/kyle/wip'"
```
Expected: `active`, `active`, and `drwx------ ... /home/kyle/wip`.

- [ ] **Step 4b: Create the GUI password file (one-time, on gateway)**

`guiPasswordFile` must exist and be **readable by the syncthing user (`kyle`)** --
`syncthing-init` runs as that user, so a root-owned file fails with "Permission
denied" and leaves no `<password>` element, locking the GUI against everyone.
Generate rather than type it: an interactive `install -Dm400 /dev/stdin` produced a
0-byte file twice in practice, and 0 bytes fails the same silent way.

```bash
ssh -t gateway 'head -c 18 /dev/urandom | base64 | sudo tee /var/lib/syncthing/gui-password >/dev/null \
  && sudo chown kyle:users /var/lib/syncthing/gui-password \
  && sudo chmod 400 /var/lib/syncthing/gui-password \
  && sudo stat -c "%s bytes, owner %U" /var/lib/syncthing/gui-password \
  && sudo systemctl restart syncthing-init'
```

Then read it once to store in a password manager: `ssh gateway 'sudo cat /var/lib/syncthing/gui-password'`.

Confirm it actually applied -- the file existing is not proof:
```bash
ssh gateway "bash -lc 'journalctl -u syncthing-init -n 5 --no-pager'"   # no "Permission denied"
```
A full rebuild is not required; `syncthing-init.service` runs
`merge-syncthing-config` and re-applies on restart.

- [ ] **Step 5: Confirm the ports answer**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://gateway:8888/
curl -s -o /dev/null -w '%{http_code}\n' http://gateway:8384/
```
Expected: an HTTP status from each (any 2xx/3xx/4xx proves the listener is up; connection refused means it is not).

- [ ] **Step 6: Commit**

```bash
git add hosts/sync-hub.nix machines/gateway/configuration.nix
git commit -m "gateway: add sync hub (atuin server, syncthing, wip storage)"
```

---

# Phase 2 — `wip`

The substantial layer. Task 3 builds and tests the core in isolation with no Nix and no gateway involved, so the hard guarantee ("never modifies your repo") is proven before anything is wired up.

## Task 3: Snapshot core, with tests proving repos stay untouched

**Files:**
- Create: `home/wip/wip.sh`
- Create: `tests/wip.test.sh`

**Interfaces:**
- Consumes: nothing
- Produces: shell functions `wip_slug <repo>`, `wip_repos`, `wip_snapshot <repo>`, and the env contract `WIP_HOST`, `WIP_REMOTE_HOST`, `WIP_REMOTE_PATH`, `WIP_ROOTS`, `WIP_CACHE`, `WIP_STATE`. Tasks 4–8 build on these exact names.

- [ ] **Step 1: Write the failing test suite**

Create `tests/wip.test.sh`. It runs against temp directories and a local bare repo — no gateway, no network.

```bash
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
```

- [ ] **Step 2: Run it and watch it fail**

```bash
nix shell nixpkgs#coreutils nixpkgs#git -c bash tests/wip.test.sh
```
Expected: FAIL — `home/wip/wip.sh: No such file or directory`.

- [ ] **Step 3: Write the snapshot core**

Create `home/wip/wip.sh`:

```bash
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
wip_snapshot() {
  local repo="$1" head slug idx tree branch sha target marker
  head="$(git -C "$repo" rev-parse --verify --quiet HEAD)" || return 0
  slug="$(wip_slug "$repo")"
  target="$(wip_push_target "$slug")"
  marker="$WIP_STATE/$slug.tree"
  mkdir -p "$WIP_STATE"

  idx="$(mktemp "${TMPDIR:-/tmp}/wip-idx.XXXXXX")"
  GIT_INDEX_FILE="$idx" git -C "$repo" read-tree "$head"
  GIT_INDEX_FILE="$idx" git -C "$repo" add -A
  tree="$(GIT_INDEX_FILE="$idx" git -C "$repo" write-tree)"
  rm -f "$idx"

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
  sha="$(git -C "$repo" commit-tree "$tree" -m \
    "wip@$WIP_HOST $(date -Iseconds) base=$(git -C "$repo" rev-parse --short "$head") branch=${branch:-DETACHED}")"

  wip_ensure_bare "$slug"
  git -C "$repo" push --force --quiet "$target" "$sha:refs/heads/wip/$WIP_HOST"
  printf '%s' "$tree" > "$marker"
}
```

- [ ] **Step 4: Run the tests until green**

```bash
nix shell nixpkgs#coreutils nixpkgs#git -c bash tests/wip.test.sh
```
Expected: `16 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add home/wip/wip.sh tests/wip.test.sh
git commit -m "wip: snapshot core with repo-untouched test suite

Builds the snapshot tree through a temp index and commits it parentless,
pushing by URL. Tests assert remotes, branches, all refs, HEAD, status
and the index byte-hash are unchanged after a snapshot, that .gitignore
is honoured, and that a clean tree deletes any stale snapshot."
```

---

## Task 4: Manifest and receive side

**Files:**
- Modify: `home/wip/wip.sh`
- Modify: `tests/wip.test.sh`

**Interfaces:**
- Consumes: `wip_slug`, `wip_repos`, `WIP_*` from Task 3
- Produces: `wip_manifest_write`, `wip_manifest_read <host>`, `wip_fetch <repo>`, `wip_shadow <slug>`, `wip_other_host`. Task 5's CLI verbs call these.

**Manifest format:** one TSV line per repo, `slug \t origin_url \t rel_path \t dirty \t head_sha`, stored at `$WIP_REMOTE_PATH/_manifest/<host>.tsv`. It covers *every* repo, not just dirty ones, because `wip clone` needs the census of clean repos too.

- [ ] **Step 1: Add failing tests for the manifest and shadow fetch**

Append to `tests/wip.test.sh` before the final summary block:

```bash
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
check "fetch: shadow diffs against the real worktree" \
  "$(git --git-dir="$(wip_shadow "$(wip_slug "$REPO")")" --work-tree="$REPO" diff --name-only refs/wip/otherhost | wc -l | tr -d ' ')" \
  "0"
teardown
```

- [ ] **Step 2: Run and watch it fail**

```bash
nix shell nixpkgs#coreutils nixpkgs#git -c bash tests/wip.test.sh
```
Expected: FAIL — `wip_manifest_write: command not found`.

- [ ] **Step 3: Implement the manifest and receive side**

Append to `home/wip/wip.sh`:

```bash
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
wip_manifest_write() {
  local repo slug url rel dirty head out
  out="$(mktemp "${TMPDIR:-/tmp}/wip-man.XXXXXX")"
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
    mkdir -p "$WIP_REMOTE_PATH/_manifest"
    mv "$out" "$(wip_manifest_path "$WIP_HOST")"
  else
    ssh "$WIP_REMOTE_HOST" "mkdir -p '$WIP_REMOTE_PATH/_manifest' && cat > '$(wip_manifest_path "$WIP_HOST")'" < "$out"
    rm -f "$out"
  fi
}

wip_manifest_read() {
  local host="$1"
  if wip_local_hub; then
    cat "$(wip_manifest_path "$host")" 2>/dev/null || true
  else
    ssh "$WIP_REMOTE_HOST" "cat '$(wip_manifest_path "$host")' 2>/dev/null" || true
  fi
}

# Pull the other host's snapshot into a shadow repo under $WIP_CACHE. The real
# repo is never opened for writing, so it gains no refs and no objects.
wip_fetch() {
  local repo="$1" slug shadow target
  slug="$(wip_slug "$repo")"
  shadow="$(wip_shadow "$slug")"
  target="$(wip_push_target "$slug")"

  if [ ! -d "$shadow" ]; then
    mkdir -p "$WIP_CACHE"
    git init --bare -q "$shadow"
  fi
  git --git-dir="$shadow" fetch --quiet --prune --force \
    "$target" 'refs/heads/wip/*:refs/wip/*' 2>/dev/null || return 0
}
```

- [ ] **Step 4: Run the tests until green**

```bash
nix shell nixpkgs#coreutils nixpkgs#git -c bash tests/wip.test.sh
```
Expected: `24 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add home/wip/wip.sh tests/wip.test.sh
git commit -m "wip: repo manifest and shadow-repo receive side

Snapshots are fetched into ~/.cache/wip/<slug>.git rather than the real
repo, so no refs land in the user's working repos. The manifest is a
per-host TSV census of every repo (dirty or not), which `wip clone`
needs to spot repos that exist on one machine only."
```

---

## Task 5: CLI verbs

**Files:**
- Modify: `home/wip/wip.sh`
- Create: `home/wip/main.sh`

**Interfaces:**
- Consumes: everything from Tasks 3–4
- Produces: `wip`, `wip push`, `wip diff`, `wip pull`, `wip undo`, `wip clone` — the user-facing surface. Task 7's timer calls `wip push --all`; Task 8's fish hook calls `wip notice`.

Every verb derives its repo from `$PWD`. There is no repo argument and no host argument.

- [ ] **Step 1: Add the repo-from-cwd helper and status query**

Append to `home/wip/wip.sh`:

```bash
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
  stat="$(git --git-dir="$shadow" --work-tree="$repo" diff --shortstat "refs/wip/$(wip_other_host)" 2>/dev/null)"
  [ -n "$stat" ] || return 0
  printf '⬇  snapshot from %s · %s ago ·%s · run `wip pull`\n' \
    "$(wip_other_host)" "$(wip_human_age "$age")" "$stat"
}
```

- [ ] **Step 2: Write the dispatcher**

Create `home/wip/main.sh`:

```bash
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
  git --git-dir="$shadow" --work-tree="$repo" diff "refs/wip/$(wip_other_host)"
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
wip_safety_ref() {
  local repo="$1" shadow="$2" idx tree sha
  idx="$(mktemp "${TMPDIR:-/tmp}/wip-safe.XXXXXX")"
  GIT_INDEX_FILE="$idx" git --git-dir="$shadow" --work-tree="$repo" add -A
  tree="$(GIT_INDEX_FILE="$idx" git --git-dir="$shadow" write-tree)"
  rm -f "$idx"
  sha="$(git --git-dir="$shadow" commit-tree "$tree" \
         -m "pre-pull@$WIP_HOST $(date -Iseconds)")"
  git --git-dir="$shadow" update-ref refs/wip/pre-pull "$sha"
}

# Deliberate by design: never overwrite a working tree without consent.
wip_cmd_pull() {
  local repo slug shadow force="${1:-}" reply
  repo="$(wip_cwd_repo)"
  [ -n "$repo" ] || { echo "wip: not in a git repo" >&2; return 1; }
  slug="$(wip_slug "$repo")"; shadow="$(wip_shadow "$slug")"
  git --git-dir="$shadow" rev-parse --verify --quiet "refs/wip/$(wip_other_host)" >/dev/null 2>&1 \
    || { echo "wip: no snapshot from $(wip_other_host) for this repo"; return 0; }

  if [ -n "$(git -C "$repo" status --porcelain)" ] && [ "$force" != "--force" ]; then
    echo "wip: your working tree has changes."
    echo "     Review with \`wip diff\`, then re-run with --force to overwrite."
    return 1
  fi

  git --git-dir="$shadow" --work-tree="$repo" diff --stat "refs/wip/$(wip_other_host)"
  printf 'Apply this snapshot over %s? [y/N] ' "$repo"
  read -r reply
  case "$reply" in
    y|Y) wip_safety_ref "$repo" "$shadow"
         git --git-dir="$shadow" --work-tree="$repo" checkout "refs/wip/$(wip_other_host)" -- .
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
  git --git-dir="$shadow" --work-tree="$repo" diff --stat refs/wip/pre-pull
  printf 'Restore? [y/N] '
  read -r reply
  case "$reply" in
    y|Y) git --git-dir="$shadow" --work-tree="$repo" checkout refs/wip/pre-pull -- .
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
  local repo n=0 notice slug url rel
  repo="$(wip_cwd_repo)"
  if [ -n "$repo" ]; then
    notice="$(wip_notice "$repo")"
    if [ -n "$notice" ]; then printf '%s' "$notice"
    else echo "wip: nothing waiting for this repo."; fi
    return 0
  fi

  echo "Snapshots waiting from $(wip_other_host):"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    notice="$(wip_notice "$repo")"
    [ -n "$notice" ] || continue
    printf '  %-40s %s' "${repo#"$HOME"/}" "$notice"; n=$((n+1))
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
  notice)    repo="$(wip_cwd_repo)"; [ -n "$repo" ] && wip_notice "$repo" ;;
  *)         echo "usage: wip [status|push [--all]|fetch|diff|pull [--force]|undo|clone]" >&2; exit 1 ;;
esac
```

- [ ] **Step 3: Test the safety ref — this is the one path that can lose work**

Append to `tests/wip.test.sh` before the final summary block:

```bash
# --- pull safety ref ---------------------------------------------------------
setup
# Local edit we must not lose, plus a snapshot from "the other host".
printf 'from-other\n' > "$REPO/tracked.txt"
wip_snapshot "$REPO"
BARE="$WIP_REMOTE_PATH/$(wip_slug "$REPO").git"
git -C "$BARE" update-ref refs/heads/wip/otherhost refs/heads/wip/testhost
git -C "$BARE" update-ref -d refs/heads/wip/testhost
printf 'my-local-work\n' > "$REPO/tracked.txt"
printf 'my-scratch\n'    > "$REPO/local-only.txt"
wip_fetch "$REPO"

SHADOW="$(wip_shadow "$(wip_slug "$REPO")")"
wip_safety_ref "$REPO" "$SHADOW"
check "safety: ref created" \
  "$(git --git-dir="$SHADOW" rev-parse --verify --quiet refs/wip/pre-pull >/dev/null && echo yes || echo no)" "yes"

# Simulate the destructive half of `wip pull`.
git --git-dir="$SHADOW" --work-tree="$REPO" checkout refs/wip/otherhost -- .
check "safety: pull did overwrite the local edit" "$(cat "$REPO/tracked.txt")" "from-other"

# Now undo it.
git --git-dir="$SHADOW" --work-tree="$REPO" checkout refs/wip/pre-pull -- .
check "safety: undo restores the overwritten file" "$(cat "$REPO/tracked.txt")" "my-local-work"
check "safety: undo restores the untracked file"   "$(cat "$REPO/local-only.txt")" "my-scratch"
check "safety: real repo still has no refs of its own" \
  "$(git -C "$REPO" for-each-ref --format='%(refname)' | grep -c '^refs/wip/')" "0"
teardown
```

- [ ] **Step 4: Run it**

```bash
nix shell nixpkgs#coreutils nixpkgs#git -c bash tests/wip.test.sh
```
Expected: `29 passed, 0 failed`. If "undo restores the untracked file" fails, `wip_safety_ref` is reading `HEAD` instead of the working tree — it must build from `add -A` against the live work-tree, with no `read-tree`.

- [ ] **Step 4b: Test that one bad repo does not abort the batch**

Off-LAN every push fails, so per-repo tolerance is load-bearing. Append to
`tests/wip.test.sh` before the final summary block:

```bash
# --- batch resilience --------------------------------------------------------
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

set +e
( set -euo pipefail; source "$HERE/../home/wip/wip.sh"; \
  while IFS= read -r r; do [ -n "$r" ] && { wip_snapshot "$r" || true; }; done < <(wip_repos) )
BATCH_RC=$?
set -e
check "batch: survives a failing repo" "$BATCH_RC" "0"
check "batch: the healthy repo still got pushed" \
  "$(git -C "$WIP_REMOTE_PATH/$(wip_slug "$REPO").git" rev-parse --verify --quiet refs/heads/wip/testhost >/dev/null && echo yes || echo no)" \
  "yes"
teardown
```

Run it: `nix shell nixpkgs#coreutils nixpkgs#git -c bash tests/wip.test.sh`
Expected: `31 passed, 0 failed`. If "the healthy repo still got pushed" fails,
the loop aborted on the broken one — the `|| true` is missing.

- [ ] **Step 5: Smoke-test the dispatcher against the sandbox**

```bash
bash -c '
  set -e
  S=$(mktemp -d); export HOME=$S/home
  export WIP_HOST=testhost WIP_REMOTE_HOST=unused WIP_REMOTE_PATH=$S/hub WIP_LOCAL_HUB=1
  export WIP_ROOTS=work WIP_CACHE=$S/cache WIP_STATE=$S/state
  mkdir -p "$HOME/work" "$WIP_REMOTE_PATH" "$WIP_CACHE" "$WIP_STATE"
  R=$HOME/work/demo; mkdir -p "$R"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  git -C "$R" remote add origin https://github.com/acme/demo.git
  echo v1 > "$R/a.txt"; git -C "$R" add -A; git -C "$R" commit -qm init
  echo v2 > "$R/a.txt"
  source home/wip/wip.sh
  wip_snapshot "$R"; wip_manifest_write
  cd "$R"; bash '"$PWD"'/home/wip/main.sh status
  rm -rf "$S"
'
```
Expected: no snapshot notice (the only snapshot is from `testhost`, i.e. this host, not the other one) and a clean exit. Any `command not found` means a function is missing from `wip.sh`.

- [ ] **Step 6: Commit**

```bash
git add home/wip/main.sh home/wip/wip.sh tests/wip.test.sh
git commit -m "wip: CLI verbs derived from cwd

status/push/fetch/diff/pull/undo/clone, all taking their repo from \$PWD.

pull is the only operation in this system that writes to a working
tree, so it captures the current tree to refs/wip/pre-pull first and
`wip undo` restores it. It also refuses a dirty tree without --force
and always confirms. clone reads the other host's manifest to
materialize repos that exist on one machine only."
```

---

## Task 6: Nix module

**Files:**
- Create: `home/wip.nix`
- Modify: `home/wsl.nix`, `home/darwin.nix`, `users/kyle/home.nix`, `users/kyle/ariane.nix`

**Interfaces:**
- Consumes: `home/wip/wip.sh`, `home/wip/main.sh`
- Produces: option `kyle.wip.{enable,host,roots,remoteHost,remotePath,interval}`; a `wip` binary on `PATH`. Task 7 reads `cfg.interval`, Task 8 reads `cfg.enable`.

- [ ] **Step 1: Write the module**

Create `home/wip.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.kyle.wip;

  # The script is assembled rather than templated so home/wip/*.sh stay
  # directly testable (see tests/wip.test.sh).
  wip = pkgs.writeShellScriptBin "wip" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath (with pkgs; [ git openssh coreutils findutils gnused ])}:$PATH"

    export WIP_HOST=${lib.escapeShellArg cfg.host}
    export WIP_REMOTE_HOST=${lib.escapeShellArg cfg.remoteHost}
    export WIP_REMOTE_PATH=${lib.escapeShellArg cfg.remotePath}
    export WIP_ROOTS=${lib.escapeShellArg (lib.concatStringsSep " " cfg.roots)}
    export WIP_CACHE="''${XDG_CACHE_HOME:-$HOME/.cache}/wip"
    export WIP_STATE="''${XDG_STATE_HOME:-$HOME/.local/state}/wip"

    # Bound git's SSH too, not just wip_hub_up's probe — the hub is LAN-only,
    # so a push attempt from off-network must fail fast rather than block.
    export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -o BatchMode=yes -o ConnectTimeout=5"

    source ${./wip/wip.sh}
    source ${./wip/main.sh}
  '';
in
{
  options.kyle.wip = {
    enable = lib.mkEnableOption "cross-machine working-tree snapshots";

    host = lib.mkOption {
      type = lib.types.str;
      description = ''
        This machine's logical name. Baked in at build time rather than read
        from `hostname` — ariane's real hostname is `kyles-macbook-pro`, which
        would produce confusing ref names.
      '';
      example = "artemis";
    };

    roots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "personal" ];
      description = ''
        Directories under $HOME to scan for repos. Independently toggleable so
        the decision about whether work repos reach the homelab is one line.
      '';
      example = [ "personal" "work" ];
    };

    remoteHost = lib.mkOption {
      type = lib.types.str;
      default = "gateway";
      description = "SSH host of the always-on hub.";
    };

    remotePath = lib.mkOption {
      type = lib.types.str;
      default = "/home/kyle/wip";
      description = "Absolute path on the hub holding the bare snapshot repos.";
    };

    interval = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Minutes between snapshot/fetch runs.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ wip ];
  };
}
```

- [ ] **Step 2: Set the host on each platform**

Append to `home/wsl.nix`:

```nix
  # Logical host name for `wip` refs. See home/wip.nix.
  kyle.wip.host = "artemis";
```

Append to `home/darwin.nix`:

```nix
  # Logical host name for `wip` refs — NOT the machine's real hostname
  # (kyles-macbook-pro), which would make for confusing ref names.
  kyle.wip.host = "ariane";
```

- [ ] **Step 3: Import and enable on both profiles**

In `users/kyle/home.nix` and `users/kyle/ariane.nix`, add to `imports`:

```nix
    ../../home/wip.nix
```

and add to each profile body:

```nix
  kyle.wip = {
    enable = true;
    roots = [ "personal" "work" ];
  };
```

- [ ] **Step 4: Track the new files and verify both platforms evaluate**

```bash
git add home/wip.nix home/wip/
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
nix eval .#nixosConfigurations.artemis.config.system.build.toplevel.drvPath
```
Expected: two store paths.

- [ ] **Step 5: Confirm the binary bakes in the right host**

```bash
nix build --no-link --print-out-paths \
  .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.config.home.path
grep -m1 WIP_HOST "$(nix eval --raw .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.config.home.path)/bin/wip"
```
Expected: `export WIP_HOST='ariane'`.

- [ ] **Step 6: Commit**

```bash
git add home/wip.nix home/wip/ home/wsl.nix home/darwin.nix users/kyle/home.nix users/kyle/ariane.nix
git commit -m "wip: Nix module, enabled on artemis and ariane

Host identity is baked at build time rather than sniffed from hostname."
```

---

## Task 7: Timer

**Files:**
- Modify: `home/wip.nix`

**Interfaces:**
- Consumes: `cfg.interval`, the `wip` binary from Task 6
- Produces: a recurring `wip push --all && wip fetch` on both platforms

- [ ] **Step 1: Add both platform backends**

In `home/wip.nix`, extend the `config` block. Add to the `let` binding first:

```nix
  tick = pkgs.writeShellScript "wip-tick" ''
    set -uo pipefail
    ${wip}/bin/wip push --all || true
    ${wip}/bin/wip fetch     || true
    ${lib.optionalString cfg.driftCheck ''
      ${pkgs.git}/bin/git -C "$HOME/nixosdotfiles" fetch --quiet || true
    ''}
  '';
```

Add the `driftCheck` option alongside the others:

```nix
    driftCheck = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Also fetch the flake repo each tick, for home/drift.nix.";
    };
```

Then replace the `config` block:

```nix
  config = lib.mkIf cfg.enable {
    home.packages = [ wip ];

    # Linux (artemis): systemd user timer.
    systemd.user = lib.mkIf pkgs.stdenv.isLinux {
      services.wip = {
        Unit.Description = "Snapshot dirty working trees to the sync hub";
        Service = {
          Type = "oneshot";
          ExecStart = "${tick}";
        };
      };
      timers.wip = {
        Unit.Description = "Run wip every ${toString cfg.interval} minutes";
        Timer = {
          OnBootSec = "2m";
          OnUnitActiveSec = "${toString cfg.interval}m";
          Persistent = true;
        };
        Install.WantedBy = [ "timers.target" ];
      };
    };

    # macOS (ariane): launchd agent.
    launchd.agents.wip = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;
      config = {
        ProgramArguments = [ "${tick}" ];
        StartInterval = cfg.interval * 60;
        RunAtLoad = true;
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/.local/state/wip/agent.log";
        StandardErrorPath = "${config.home.homeDirectory}/.local/state/wip/agent.log";
      };
    };

    home.activation.wipStateDir =
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        $DRY_RUN_CMD mkdir -p "$HOME/.local/state/wip" "$HOME/.cache/wip"
      '';
  };
```

- [ ] **Step 2: Verify both platforms still evaluate**

```bash
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
nix eval .#nixosConfigurations.artemis.config.system.build.toplevel.drvPath
```
Expected: two store paths. A `The option launchd.agents...does not exist` error means the `mkIf isDarwin` was placed outside the attribute rather than on its value.

- [ ] **Step 3: Confirm only the right backend is produced**

```bash
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.config.launchd.agents.wip.enable
nix eval .#nixosConfigurations.artemis.config.home-manager.users.kyle.systemd.user.timers.wip.Timer.OnUnitActiveSec
```
Expected: `true`, then `"5m"`.

- [ ] **Step 4: Commit**

```bash
git add home/wip.nix
git commit -m "wip: 5-minute timer via systemd (linux) and launchd (darwin)"
```

---

## Task 8: Fish cd-hook

**Files:**
- Modify: `home/wip.nix`

**Interfaces:**
- Consumes: `wip notice` from Task 5
- Produces: a passive notice on entering a repo with a waiting snapshot

**Why a hook rather than a CLI habit:** the user's stated constraint was that they will only remember this exists while inside a repo. The hook removes the need to remember at all. It reads local refs from the shadow cache only — no SSH, sub-millisecond, silent when there is nothing to say.

- [ ] **Step 1: Add the hook**

Add to the `config` block in `home/wip.nix`:

```nix
    programs.fish.functions.__wip_on_pwd = {
      description = "Announce a waiting wip snapshot on entering a repo";
      onVariable = "PWD";
      body = ''
        # Local ref reads only — no network. Silent unless there is news.
        ${wip}/bin/wip notice 2>/dev/null
      '';
    };
```

- [ ] **Step 2: Verify it evaluates and lands in the fish config**

```bash
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
nix eval --raw .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.config.programs.fish.functions.__wip_on_pwd.onVariable
```
Expected: a store path, then `PWD`.

- [ ] **Step 3: Confirm it is fast enough to run on every `cd`**

After activating on ariane:

```bash
cd ~/work/docresolve && time wip notice
```
Expected: real time under ~50 ms. If it is slower, the shadow cache is missing and `wip_fetch` is being reached — check `~/.cache/wip/` exists.

- [ ] **Step 4: Commit**

```bash
git add home/wip.nix
git commit -m "wip: fish PWD hook announcing waiting snapshots"
```

---

# Phase 3 — User environment

Independent of each other. Any subset can land.

## Task 9: Canonical folder layout

**Files:**
- Modify: `home/folders.nix`, `home/wsl.nix`

**Interfaces:**
- Consumes: nothing
- Produces: `~/personal`, `~/work`, `~/notes`, `~/scratch` on both machines — the roots Tasks 6 and 12 scan

- [ ] **Step 1: Replace the folder module**

`home/folders.nix` currently creates `~/personal` and `~/work` and writes a `~/work/.gitconfig`. Extend it, preserving the gitconfig:

```nix
{ lib, config, pkgs, ... }:

# Canonical layout, identical on every machine. Anything host-specific — in
# particular artemis's symlinks into the Windows filesystem — lives in
# home/wsl.nix, so these directories only ever contain real files and the
# sync layers never have to reason about cross-platform symlinks.
{
  home.activation.createDirsAndFiles = lib.hm.dag.entryAfter ["writeBoundary"] ''
    $DRY_RUN_CMD mkdir -p "$HOME/personal"
    $DRY_RUN_CMD mkdir -p "$HOME/work"
    $DRY_RUN_CMD mkdir -p "$HOME/notes"
    $DRY_RUN_CMD mkdir -p "$HOME/scratch"
    $DRY_RUN_CMD cat > "$HOME/work/.gitconfig" <<EOF
    [user]
      email = kmello@broadriverrehab.com
    EOF
  '';
}
```

- [ ] **Step 2: Document artemis's Windows-backed paths**

Add to `home/wsl.nix`, recording what was found on the live machine:

```nix
  # Paths backed by the Windows filesystem. These exist on artemis only; they
  # cannot cross to macOS, and they must never enter a sync root.
  #
  # Already present on disk (created by hand, left as-is):
  #   ~/.aws                  -> /mnt/c/Users/kylem/.aws
  #   ~/.azure                -> /mnt/c/Users/kylem/.azure
  #   ~/.docker/contexts      -> /mnt/c/Users/kylem/.docker/contexts
  #   ~/.docker/features.json -> /mnt/c/Users/kylem/.docker/features.json
  #
  # ~/work/work-knowledge-repo -> /mnt/c/Users/kylem/Vaults/work-knowledge-repo
  # is a git repo living INSIDE a sync root, on the 9p filesystem. `wip_repos`
  # uses plain `find` (no -L), which does not traverse symlinks, so it is
  # skipped. Do not add -L to that find without excluding this path first.
```

- [ ] **Step 3: Verify**

```bash
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
nix eval .#nixosConfigurations.artemis.config.system.build.toplevel.drvPath
```
Expected: two store paths.

- [ ] **Step 4: Commit**

```bash
git add home/folders.nix home/wsl.nix
git commit -m "home: canonical ~/personal ~/work ~/notes ~/scratch layout

Documents artemis's Windows-backed symlinks, including the
work-knowledge-repo vault that sits inside a sync root and is skipped
because wip_repos uses find without -L."
```

---

## Task 10: Atuin with the fzf front-end

**Files:**
- Create: `home/atuin.nix`
- Modify: `home/fish.nix`, `users/kyle/home.nix`, `users/kyle/ariane.nix`

**Interfaces:**
- Consumes: the Atuin server from Task 2
- Produces: `Ctrl+R` backed by Atuin, wearing the fzf.fish interface

**Hard requirement:** the interface must not change. Only the data source does. The function below is a clone of upstream `_fzf_search_history` with one line swapped — `_fzf_wrapper`, `--multi`, `--scheme=history`, the `History> ` prompt, the `fish_indent --ansi` preview, the U+2502 separator, and `$fzf_history_opts` are all preserved verbatim.

- [ ] **Step 1: Write the module**

Create `home/atuin.nix`:

```nix
{ config, lib, pkgs, ... }:

{
  programs.atuin = {
    enable = true;

    # Atuin's own Ctrl-R and up-arrow bindings are suppressed; the fzf.fish
    # interface below owns Ctrl-R instead. Verified against atuin 18.17.1:
    # --disable-ctrl-r, --disable-up-arrow, --disable-ai all exist.
    flags = [ "--disable-ctrl-r" "--disable-up-arrow" ];

    settings = {
      # The Home Manager example defaults to "prefix"; do not inherit it.
      search_mode = "fuzzy";
      filter_mode = "global";
      sync_address = "http://gateway:8888";
      auto_sync = true;
      sync_frequency = "5m";
      update_check = false;
    };
  };

  # A clone of fzf.fish's _fzf_search_history with the data source swapped from
  # `builtin history` to `atuin search`. Everything else is upstream's, so the
  # interface is unchanged. Dropped from upstream: `builtin history merge`,
  # which has no Atuin equivalent.
  programs.fish.functions._fzf_atuin_history = {
    description = "Search Atuin history. Replace the command line with the selected command.";
    body = ''
      set -f time_prefix_regex '^.*? │ '
      set -f commands_selected (
          atuin search --print0 --limit 10000 --format "{time} │ {command}" |
          _fzf_wrapper --read0 \
              --print0 \
              --multi \
              --scheme=history \
              --prompt="History> " \
              --query=(commandline) \
              --preview="string replace --regex '$time_prefix_regex' \'\' -- {} | fish_indent --ansi" \
              --preview-window="bottom:3:wrap" \
              $fzf_history_opts |
          string split0 |
          string replace --regex $time_prefix_regex \'\'
      )

      if test $status -eq 0
          commandline --replace -- $commands_selected
      end

      commandline --function repaint
    '';
  };
}
```

- [ ] **Step 2: Bind it after vi mode is established**

`home/fish.nix` calls `fish_vi_key_bindings` *after* its `bind` lines. Atuin's init hook and this binding must both land after that call, or the binds will not survive in vi mode. Append to `interactiveShellInit`, at the very end:

```fish
      # Ctrl-R: fzf.fish's interface over Atuin's cross-machine database.
      # Must come after fish_vi_key_bindings above. Both modes are needed
      # because vi mode keeps separate binding tables.
      bind \cr _fzf_atuin_history
      bind -M insert \cr _fzf_atuin_history
```

- [ ] **Step 3: Import on both profiles**

Add `../../home/atuin.nix` to `imports` in `users/kyle/home.nix` and `users/kyle/ariane.nix`.

- [ ] **Step 4: Verify**

```bash
git add home/atuin.nix
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
nix eval .#nixosConfigurations.artemis.config.system.build.toplevel.drvPath
```
Expected: two store paths.

- [ ] **Step 5: Register against the hub (one-time, per machine)**

```bash
atuin register -u kyle -e kmello@broadriverrehab.com   # first machine only
atuin login -u kyle                                     # second machine
atuin import auto && atuin sync
```
Then close registration on gateway: set `services.atuin.openRegistration = false;` in `hosts/sync-hub.nix` and rebuild.

- [ ] **Step 6: Resolve the two open format questions against real output**

```bash
# Is --print0 a record SEPARATOR (needed by fzf --read0) or only a terminator?
atuin search --print0 --limit 3 --format "{time} │ {command}" | xxd | grep -c '0000'
# What does {time} actually look like next to fzf.fish's "%m-%d %H:%M:%S"?
atuin search --limit 3 --format "{time} │ {command}"
```
If `--print0` turns out to be terminator-only, replace the pipeline's first stage with
`atuin search --cmd-only --limit 10000 | string join0` and drop the time column.
If `{time}` is much wider than `MM-DD HH:MM:SS`, insert a
`| string replace --regex '^(\S+ \S+)\S*' '$1'` stage before `_fzf_wrapper`.

- [ ] **Step 7: Confirm the interface is unchanged**

Press `Ctrl+R`. Expected: the same `History> ` prompt, the same bottom preview pane, the same `--cycle --layout=reverse --border --height=90%` frame — populated with commands from the other machine. Confirm the other five fzf.fish widgets still work: `Ctrl+T`, `Ctrl+Alt+L`, `Ctrl+Alt+S`, `Ctrl+V`, `Ctrl+Alt+P`.

- [ ] **Step 8: Commit**

```bash
git add home/atuin.nix home/fish.nix users/kyle/home.nix users/kyle/ariane.nix
git commit -m "atuin: self-hosted history behind the fzf.fish interface

Atuin's own Ctrl-R is disabled and _fzf_search_history is cloned with
only its data source swapped, so the interface is byte-identical and the
other five fzf.fish widgets are untouched. search_mode is pinned to
fuzzy; the HM example defaults to prefix."
```

---

## Task 11: Reconcile and share Claude config

**Files:**
- Create: `home/claude.nix`, `claude/`, `claude/local/{artemis,ariane}.json`
- Modify: `users/kyle/home.nix`, `users/kyle/ariane.nix`

**Interfaces:**
- Consumes: nothing
- Produces: `~/.claude/{CLAUDE.md,skills,agents,commands,settings.json,settings.local.json}` versioned in the flake, writable in place, with machine-specific values isolated per host

**Why this is a reconciliation and not a copy.** The two machines have genuinely
divergent Claude config, in *both* directions. A naive "copy from one machine
into the repo, symlink on both" silently destroys whatever only existed on the
second machine. Measured 2026-07-28:

| Only on artemis | Only on ariane |
|---|---|
| `model: "opus[1m]"` | `~/.claude/CLAUDE.md` (artemis has **no** such file) |
| `includeCoAuthoredBy: false` | `skills/deploying-laravel-cloud` (artemis's `skills/` is empty) |
| `permissions.allow: [WebSearch, WebFetch]` | plugins: `typescript-lsp`, `pr-review-toolkit`, `skill-creator` |
| plugins: `ui-ux-pro-max`, `security-guidance`, `claude-code-setup`, `microsoft-docs` | `voice`, `voiceEnabled`, `attribution.commit` |
| plugins: `kmello-skills@kmello`, `aegis-jira@kmello-dev`, `work-os@kmello-dev` | |
| `extraKnownMarketplaces` (4 entries, 2 with absolute paths) | |
| `spinnerVerbs` (98 custom verbs) | |
| `skipWorkflowUsageWarning`, `remoteControlAtStartup` | |

**Verified prerequisite (2026-07-28): Claude Code writes *through* a symlink.**
Tested by replacing `~/.claude/settings.json` with a symlink and running
`claude plugin disable typescript-lsp@claude-plugins-official`. The symlink
survived, and the change landed in the target file. So `mkOutOfStoreSymlink`
works for `settings.json` and `/config`, `/plugin`, and "always allow" keep
functioning. (Original restored byte-for-byte afterward; sha matched.)

### Three layers of path dependency

1. `settings.json` → `extraKnownMarketplaces.kmello` = `/home/kyle/personal/claude-plugins`,
   `.kmello-dev` = `/home/kyle/work/dev-plugins`. Different on macOS.
2. Inside `claude-plugins`: `kmello-skills/skills/managing-homebox/SKILL.md:9,16`
   hardcodes `/home/kyle/personal/homebox`. Fixed in Task 14.
   (`dev-plugins` is clean — no absolute paths.)
3. The repos themselves: `claude-plugins`, `dev-plugins`, and `homebox` all exist
   on artemis and are **absent on ariane**.

**Ordering:** step 1 below must complete before ariane's custom marketplaces
resolve, or Claude Code will log missing-marketplace errors on every start.

- [ ] **Step 0: Give ariane the existing `home/claude-code.nix`**

`home/claude-code.nix` already exists (commit `5e4ef1b`, authored 2026-07-19) and
solves the `~/.claude.json` problem properly: rather than owning the file, it
idempotently deep-merges declared MCP servers into it at activation with
`jq --argjson d "$desired" '. * $d'`, validating the JSON first and preserving
everything else. **Do not reinvent this** — the rest of this task is built around
`settings.json`, and `.claude.json` is that module's job.

It is imported by `users/kyle/home.nix`, so all four NixOS hosts register the
MetaMCP `personal` endpoint. `users/kyle/ariane.nix` does **not** import it, so
**ariane currently has no MetaMCP server at all.** Fix that:

```nix
    ../../home/claude-code.nix
```

added to `imports` in `users/kyle/ariane.nix`. Then, once per host:

```bash
claude mcp login personal
```

Auth is OAuth and the token goes to the OS keychain, so nothing secret enters
git. The module's own comment anticipates more endpoints — *"Extend this to add
more endpoints later"* — and there are four waiting, because only `personal` is
declarative. The rest were added with `claude mcp add` and live on one machine
each (measured 2026-07-28 from each host's `~/.claude.json`):

| Server | Definition | artemis | ariane |
|---|---|---|---|
| `personal` | `http` → `mcp.kmello.dev/metamcp/personal/mcp` | ✅ declarative | ❌ |
| `git` | `stdio` → `uvx mcp-server-git` | ✅ imperative | ❌ |
| `kubernetes` | `stdio` → `npx mcp-server-kubernetes` | ✅ imperative | ❌ |
| `atlassian-aegis` | `http` → `mcp.atlassian.com/v1/mcp/authv2` | ✅ imperative | ❌ |
| `teams-mcp` | `stdio` → `npx -y @floriscornel/teams-mcp@latest` | ❌ | ✅ imperative |

**All five are portable** — `uvx` comes from `uv` and `npx` from `nodejs_24`, both
already in `home/packages/dev.nix`, and the other two are plain URLs. So move all
of them into the module's `mcpServers` set and they become declared once and
shared, rather than drifting per-machine:

```nix
  mcpServers = {
    personal         = { type = "http";  url = "https://mcp.kmello.dev/metamcp/personal/mcp"; };
    atlassian-aegis  = { type = "http";  url = "https://mcp.atlassian.com/v1/mcp/authv2"; };
    git              = { type = "stdio"; command = "uvx"; args = [ "mcp-server-git" ]; env = {}; };
    kubernetes       = { type = "stdio"; command = "npx"; args = [ "mcp-server-kubernetes" ]; env = {}; };
    teams-mcp        = { type = "stdio"; command = "npx"; args = [ "-y" "@floriscornel/teams-mcp@latest" ]; env = {}; };
  };
```

The jq deep-merge makes this safe to apply to a host that already has some of
them — verified on artemis, where activation added `personal` while leaving
`git`, `kubernetes` and `atlassian-aegis` untouched.

**On `atlassian-aegis` specifically:** the `dev-plugins` repo *documents* it as a
manual prerequisite but does not declare it. `dev-plugins/README.md:19` tells you
to run `claude mcp add --transport http --scope user atlassian-aegis ...`, and
`aegis-jira/skills/creating-adt-tickets/SKILL.md:16,22` hard-depends on a server
by that name. Declaring it here replaces that manual step. Note it does **not**
remove the one-time interactive auth — `/mcp` → authenticate → select the
`aegistherapies` site — which is per-host regardless, same as `personal`.
Optionally simplify `dev-plugins/README.md` afterward to point at the flake
instead of the `claude mcp add` line; that is a commit to that repo, not this one.

Confirm afterward that both hosts agree:
```bash
jq -S '.mcpServers | keys' ~/.claude.json
ssh artemis "bash -lc 'jq -S \".mcpServers | keys\" ~/.claude.json'"
```
Expected: the same five keys on both.

Verify: `nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath`,
then after activation `jq '.mcpServers' ~/.claude.json` shows `personal`.

- [ ] **Step 1: Clone the prerequisite repos onto ariane**

The two custom marketplaces are `directory` sources, so the repos must exist
before the settings referencing them are applied.

```bash
git clone git@github.com:kylemello/claude-plugins.git ~/personal/claude-plugins
git clone git@github.com:kylemello/dev-plugins.git    ~/work/dev-plugins
git clone git@gitea.kmello.dev:kylemello/homebox-manager.git ~/personal/homebox
```

Note homebox's origin is your **self-hosted Gitea** (`gitea.kmello.dev`), not
GitHub, and the directory name (`homebox`) differs from the repo name
(`homebox-manager`) — hence the explicit target path. Confirm ariane can reach
Gitea before relying on it:
```bash
ssh -T git@gitea.kmello.dev 2>&1 | head -2
ls -d ~/personal/claude-plugins ~/work/dev-plugins ~/personal/homebox
```

- [ ] **Step 2: Union the two settings.json into the repo**

Merged with `jq` rather than by hand, so the 98 `spinnerVerbs` and 19 plugin
entries are copied exactly rather than transcribed. `*` deep-merges objects;
the only key both files set is `permissions.defaultMode`, and both say `auto`.

```bash
mkdir -p claude/local
ssh artemis "bash -lc 'cat ~/.claude/settings.json'" > /tmp/artemis-settings.json
cp ~/.claude/settings.json /tmp/ariane-settings.json

# artemis first so ariane's unique keys land on top; artemis's model and
# spinnerVerbs survive because ariane has no such keys.
jq -s '.[0] * .[1]' /tmp/artemis-settings.json /tmp/ariane-settings.json \
  > /tmp/merged.json

# extraKnownMarketplaces is per-machine (absolute paths), so it leaves the
# shared file entirely. ALL four entries move, not just the two with paths —
# it is unverified whether settings.local.json deep-merges or replaces this
# key, and moving all of them makes the answer irrelevant.
jq 'del(.extraKnownMarketplaces)' /tmp/merged.json > claude/settings.json

# Sanity: every plugin from both machines is present.
jq -r '.enabledPlugins | keys[]' claude/settings.json | wc -l   # expect 19
jq -r '.model, .effortLevel, .editorMode' claude/settings.json  # opus[1m] xhigh vim
jq '.spinnerVerbs.verbs | length' claude/settings.json          # expect 98
```

- [ ] **Step 3: Write the per-machine files**

Paths differ per host, so these are the only divergent files. Include ariane's
existing podman permissions so nothing is lost.

`claude/local/artemis.json`:
```json
{
  "extraKnownMarketplaces": {
    "claude-code-plugins": {
      "source": { "source": "github", "repo": "anthropics/claude-code" }
    },
    "ui-ux-pro-max-skill": {
      "source": { "source": "github", "repo": "nextlevelbuilder/ui-ux-pro-max-skill" }
    },
    "kmello": {
      "source": { "source": "directory", "path": "/home/kyle/personal/claude-plugins" }
    },
    "kmello-dev": {
      "source": { "source": "directory", "path": "/home/kyle/work/dev-plugins" }
    }
  }
}
```

`claude/local/ariane.json` — same, with `/Users/kyle` paths, plus the podman
permissions that were already in ariane's `settings.local.json`:
```json
{
  "extraKnownMarketplaces": {
    "claude-code-plugins": {
      "source": { "source": "github", "repo": "anthropics/claude-code" }
    },
    "ui-ux-pro-max-skill": {
      "source": { "source": "github", "repo": "nextlevelbuilder/ui-ux-pro-max-skill" }
    },
    "kmello": {
      "source": { "source": "directory", "path": "/Users/kyle/personal/claude-plugins" }
    },
    "kmello-dev": {
      "source": { "source": "directory", "path": "/Users/kyle/work/dev-plugins" }
    }
  },
  "permissions": {
    "allow": [
      "Bash(podman ps:*)",
      "Bash(podman stop *)",
      "Bash(podman rm *)",
      "Bash(podman volume *)"
    ]
  }
}
```

- [ ] **Step 4: Union CLAUDE.md and skills**

artemis has no `CLAUDE.md` at all, so ariane's is the whole content. Reword the
heading — once shared it is no longer "this machine".

```bash
cp ~/.claude/CLAUDE.md claude/CLAUDE.md
sed -i '' 's/^# User preferences (all projects on this machine)$/# User preferences (all projects, all machines)/' claude/CLAUDE.md

# artemis's skills/ is empty; ariane has one. Union = ariane's.
mkdir -p claude/skills claude/agents claude/commands
cp -R ~/.claude/skills/deploying-laravel-cloud claude/skills/
touch claude/agents/.keep claude/commands/.keep

# Confirm nothing on artemis is being dropped.
ssh artemis "bash -lc 'ls ~/.claude/skills ~/.claude/agents ~/.claude/commands 2>&1'"
```
Expected: artemis's `skills/` empty, `agents/` and `commands/` absent. If any
has content, copy it in before continuing — that is the loss this task exists
to prevent.

- [ ] **Step 5: Write the module**

Create `home/claude.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  # Point at the live working copy, not the nix store, so edits take effect
  # immediately and land in git. mkOutOfStoreSymlink is what makes the target
  # writable — a plain home.file source would be a read-only store path, and
  # Claude Code needs to write settings.json for /config and /plugin to work.
  repo = "${config.home.homeDirectory}/nixosdotfiles/claude";
  link = p: config.lib.file.mkOutOfStoreSymlink "${repo}/${p}";
in
{
  options.kyle.claude.host = lib.mkOption {
    type = lib.types.str;
    description = ''
      Which claude/local/<host>.json this machine uses. Set alongside
      kyle.wip.host in home/wsl.nix and home/darwin.nix.
    '';
    example = "artemis";
  };

  config = {
    # Verified 2026-07-28: Claude Code writes THROUGH these symlinks rather than
    # replacing them, so /config, /plugin and "always allow" all keep working
    # and their changes land in git.
    #
    # settings.json is shared: enabling a plugin on one machine propagates to
    # the other on the next `git pull`. settings.local.json is per-host, holding
    # only what genuinely cannot be shared (absolute marketplace paths).
    #
    # Deliberately NOT managed:
    #   projects/          session transcripts, machine-specific paths, large
    #   history.jsonl      append-only from two machines, would conflict
    #   .credentials.json  secret
    #   .claude.json       129 KB of per-project state and MCP servers; uses
    #                      write-then-rename, so symlinking it is unsafe. It is
    #                      instead deep-merged into by home/claude-code.nix --
    #                      see Step 0 below.
    #   cache/ daemon/ session-env/ shell-snapshots/ telemetry/ file-history/
    #   backups/ plugins/  all derived or machine-local
    home.file = {
      ".claude/CLAUDE.md".source          = link "CLAUDE.md";
      ".claude/skills".source             = link "skills";
      ".claude/agents".source             = link "agents";
      ".claude/commands".source           = link "commands";
      ".claude/settings.json".source      = link "settings.json";
      ".claude/settings.local.json".source = link "local/${config.kyle.claude.host}.json";
    };
  };
}
```

- [ ] **Step 6: Set the host and import on both profiles**

Append to `home/wsl.nix`:
```nix
  kyle.claude.host = "artemis";
```

Append to `home/darwin.nix`:
```nix
  kyle.claude.host = "ariane";
```

Add `../../home/claude.nix` to `imports` in `users/kyle/home.nix` and
`users/kyle/ariane.nix`.

- [ ] **Step 7: Verify it evaluates and picks the right local file**

```bash
git add home/claude.nix claude/
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
nix eval .#nixosConfigurations.artemis.config.system.build.toplevel.drvPath
nix eval --raw .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.config.kyle.claude.host
```
Expected: two store paths, then `ariane`.

- [ ] **Step 8: Activate and confirm writes reach git**

Home Manager refuses to clobber unmanaged files, so back them up first — `-b`
renames anything in the way to `<file>.backup` instead of failing.

```bash
home-manager switch -b backup --flake .#ariane

readlink ~/.claude/settings.json        # → ~/nixosdotfiles/claude/settings.json
readlink ~/.claude/settings.local.json  # → ~/nixosdotfiles/claude/local/ariane.json

# A real settings write must land in the repo.
claude plugin disable typescript-lsp@claude-plugins-official
git -C ~/nixosdotfiles status --short claude/     # expect: M claude/settings.json
claude plugin enable typescript-lsp@claude-plugins-official
git -C ~/nixosdotfiles checkout -- claude/settings.json
```
Expected: both symlinks resolve into the repo (not `/nix/store/...`), and the
plugin toggle shows up as a git modification. If `git status` is clean after the
toggle, the write did not reach the repo — stop and re-check the symlink.

- [ ] **Step 9: Confirm Claude Code is happy on both**

```bash
claude doctor 2>&1 | tail -20
ssh artemis "bash -lc 'claude doctor 2>&1 | tail -20'"
```
Expected: no missing-marketplace or unreadable-settings errors. A missing
marketplace on ariane means Step 1's clones did not land.

- [ ] **Step 10: Commit**

```bash
git add claude/ home/claude.nix home/wsl.nix home/darwin.nix \
        users/kyle/home.nix users/kyle/ariane.nix
git commit -m "claude: reconcile and share config across both machines

Union of both machines' settings.json rather than a copy from one --
artemis contributed model opus[1m], the WebSearch/WebFetch allowlist,
spinnerVerbs and 7 plugins; ariane contributed CLAUDE.md (artemis had
none), the deploying-laravel-cloud skill, and 3 plugins. Merged with jq
so nothing was transcribed by hand.

settings.json is shared through the repo, so /config and /plugin changes
propagate between machines via git -- verified that Claude Code writes
through the symlink rather than replacing it. extraKnownMarketplaces has
absolute, platform-specific paths, so all four entries live in
per-host claude/local/<host>.json instead."
```

---
## Task 12: Syncthing clients for loose files

**Files:**
- Create: `home/sync.nix`
- Modify: `hosts/sync-hub.nix`, `users/kyle/home.nix`, `users/kyle/ariane.nix`

**Interfaces:**
- Consumes: the Syncthing server from Task 2, `~/notes` and `~/scratch` from Task 9
- Produces: `~/notes` and `~/scratch` replicated through gateway

- [ ] **Step 1: Collect the device IDs**

Syncthing generates a device ID on first run. Start it on each machine, then read the IDs — they are needed on both ends.

```bash
ssh gateway "bash -lc 'syncthing --device-id --home=/home/kyle/.config/syncthing'"
ssh artemis "bash -lc 'syncthing --device-id --home=\$HOME/.config/syncthing'"
syncthing --device-id --home="$HOME/Library/Application Support/Syncthing"
```
Record all three. If a command fails because the config does not exist yet, run `syncthing generate --home=<dir>` first.

- [ ] **Step 2: Write the client module**

Create `home/sync.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  # Device IDs collected in Step 1. Not secret — they are public keys.
  devices = {
    gateway = "PASTE-GATEWAY-DEVICE-ID";
    artemis = "PASTE-ARTEMIS-DEVICE-ID";
    ariane  = "PASTE-ARIANE-DEVICE-ID";
  };
in
{
  # Scope is deliberately narrow: loose files only. Repos go through `wip`
  # (home/wip.nix) and config goes through the flake, so no .git directory
  # ever enters a Syncthing folder and the lock-file hazard cannot arise.
  services.syncthing = {
    enable = true;
    overrideDevices = true;
    overrideFolders = true;

    settings = {
      devices = {
        gateway.id = devices.gateway;
        artemis.id = devices.artemis;
        ariane.id  = devices.ariane;
      };

      folders = {
        "notes" = {
          path = "${config.home.homeDirectory}/notes";
          devices = [ "gateway" ];   # star topology: everything via the hub
        };
        "scratch" = {
          path = "${config.home.homeDirectory}/scratch";
          devices = [ "gateway" ];
        };
      };

      options.urAccepted = -1;
    };
  };
}
```

- [ ] **Step 3: Fill the same IDs into the hub**

In `hosts/sync-hub.nix`, add the `devices` block to `services.syncthing.settings` and restore the folder `devices` lists if Task 2 Step 3 required commenting them out:

```nix
      devices = {
        artemis.id = "PASTE-ARTEMIS-DEVICE-ID";
        ariane.id  = "PASTE-ARIANE-DEVICE-ID";
      };
```

- [ ] **Step 4: Import on both profiles**

Add `../../home/sync.nix` to `imports` in `users/kyle/home.nix` and `users/kyle/ariane.nix`.

- [ ] **Step 5: Verify**

```bash
git add home/sync.nix
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
nix eval .#nixosConfigurations.gateway.config.system.build.toplevel.drvPath
```
Expected: two store paths.

- [ ] **Step 6: Prove a file crosses**

```bash
echo "from ariane $(date)" > ~/notes/roundtrip.txt
sleep 60
ssh gateway "bash -lc 'cat /home/kyle/notes/roundtrip.txt'"
ssh artemis "bash -lc 'cat ~/notes/roundtrip.txt'"
```
Expected: the same line from both. If gateway has it but artemis does not, artemis's Syncthing has not accepted the folder — check `systemctl --user status syncthing` there.

- [ ] **Step 7: Commit**

```bash
git add home/sync.nix hosts/sync-hub.nix users/kyle/home.nix users/kyle/ariane.nix
git commit -m "sync: syncthing for ~/notes and ~/scratch via gateway"
```

---

## Task 13: Config drift alarm

**Files:**
- Create: `home/drift.nix`
- Modify: `users/kyle/home.nix`, `users/kyle/ariane.nix`

**Interfaces:**
- Consumes: the flake fetch performed each tick by Task 7's `tick` script
- Produces: a shell-start warning when the machine has not rebuilt

- [ ] **Step 1: Write the module**

Create `home/drift.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  repo = "${config.home.homeDirectory}/nixosdotfiles";
  stamp = "${config.home.homeDirectory}/.local/state/wip/last-switch";
in
{
  # Record the flake commit at activation time. The check below compares it
  # against the repo's current HEAD plus whatever the timer has fetched.
  home.activation.recordFlakeRev = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD mkdir -p "$(dirname ${stamp})"
    if [ -d "${repo}/.git" ]; then
      $DRY_RUN_CMD ${pkgs.git}/bin/git -C "${repo}" rev-parse HEAD > "${stamp}" 2>/dev/null || true
    fi
  '';

  # Warn at shell start. Two local reads (a file and a git ref) — no network,
  # because home/wip.nix's timer already did the fetch.
  programs.fish.interactiveShellInit = lib.mkAfter ''
    if test -f ${stamp}; and test -d ${repo}/.git
        set -l switched (cat ${stamp})
        set -l current (git -C ${repo} rev-parse HEAD 2>/dev/null)
        set -l upstream (git -C ${repo} rev-parse '@{u}' 2>/dev/null)
        if test -n "$current"; and test "$switched" != "$current"
            set_color yellow
            echo "⚠  nixosdotfiles moved since your last switch — run ./update.sh"
            set_color normal
        else if test -n "$upstream"; and test "$current" != "$upstream"
            set -l behind (git -C ${repo} rev-list --count HEAD..'@{u}' 2>/dev/null)
            set_color yellow
            echo "⚠  nixosdotfiles is $behind commit(s) behind the other machine — git pull && ./update.sh"
            set_color normal
        end
    end
  '';
}
```

- [ ] **Step 2: Import on both profiles**

Add `../../home/drift.nix` to `imports` in `users/kyle/home.nix` and `users/kyle/ariane.nix`.

- [ ] **Step 3: Verify**

```bash
git add home/drift.nix
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
nix eval .#nixosConfigurations.artemis.config.system.build.toplevel.drvPath
```
Expected: two store paths.

- [ ] **Step 4: Prove it fires and then clears**

```bash
home-manager switch --flake .#ariane
exec fish -l                                     # expect: no warning
git -C ~/nixosdotfiles commit --allow-empty -m "drift test"
exec fish -l                                     # expect: the yellow warning
git -C ~/nixosdotfiles reset --hard HEAD~1
exec fish -l                                     # expect: no warning
```

- [ ] **Step 5: Commit**

```bash
git add home/drift.nix users/kyle/home.nix users/kyle/ariane.nix
git commit -m "home: warn at shell start when the flake has moved since switch"
```

---

## Task 14: Reconcile the non-Claude divergence

**Files:**
- Modify: `home/fish.nix`, `home/packages/dev.nix`
- External: `~/personal/claude-plugins` (a separate repo — its own commit)

**Interfaces:**
- Consumes: nothing
- Produces: `q` available on both machines; `sqlc` from nixpkgs; the homebox skill portable

Surveyed 2026-07-28. `~/.config` divergence (34 entries on artemis vs 12 on
ariane) is **deliberately deferred** — most of it is tool-generated, and it is
easier to reconcile once the flake and `~/notes` are already shared.

Homebrew was surveyed and **left alone**. The premise that brew formulae shadow
Nix does not hold: `~/.nix-profile/bin` is PATH position 10 and
`/opt/homebrew/bin` is 13, so **Nix already wins**. The formulae that do resolve
to Homebrew (`composer`, `fnm`, `rbenv`, `ripgrep-all`, `bash`) are ones Nix
provides nothing by that name — removing them would break `composer` outright
and delete `ripgrep-all` entirely. Only brew's `coreutils` is redundant, and it
installs `g`-prefixed names that coexist harmlessly.

- [ ] **Step 1: Move `q.fish` into the flake**

artemis has a hand-written `~/.config/fish/functions/q.fish` — an AI
command-suggestion function — that ariane lacks entirely. It is not
Nix-managed, so it exists on exactly one machine.

Its system prompt hardcodes `"fish shell on NixOS/WSL2"`, which is wrong on
macOS, so the platform string comes from Nix instead.

Pull the current source and add it to `programs.fish.functions` in
`home/fish.nix`:

```bash
ssh artemis "bash -lc 'cat ~/.config/fish/functions/q.fish'" > /tmp/q.fish
```

In `home/fish.nix`, inside `programs.fish.functions`, add `q` with the body from
`/tmp/q.fish` minus its `function q ... end` wrapper (Home Manager supplies
that), and with this one line changed:

```nix
      # Platform string comes from Nix so the prompt is correct on both hosts;
      # the original hardcoded "NixOS/WSL2", which is wrong on macOS.
      q = {
        description = "AI command suggestion";
        body = ''
          # ... body from /tmp/q.fish, with the system_prompt line replaced by:
          set -l system_prompt "You are a command generator for fish shell on ${
            if pkgs.stdenv.isDarwin then "macOS (nix-managed)" else "NixOS/WSL2"
          }. Output ONLY the raw shell command. No explanations, no markdown, no backticks, no code blocks. If multiple commands are needed, join with && or ; on one line."
        '';
      };
```

Then remove the now-shadowed hand-made copy on artemis, so the Nix-generated one
is authoritative:

```bash
ssh artemis "bash -lc 'mv ~/.config/fish/functions/q.fish ~/.config/fish/functions/q.fish.pre-nix'"
```

- [ ] **Step 2: Verify `q` exists on both**

```bash
git add home/fish.nix
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
nix eval .#nixosConfigurations.artemis.config.system.build.toplevel.drvPath
```
Expected: two store paths. After activation, `type q` in fish resolves on both,
and `q --help`-style misuse (`q` with no args) prints the usage line.

- [ ] **Step 3: Add `sqlc` to the shared package set**

artemis has `sqlc` installed via `go install` into `~/go/bin`; ariane does not.
It is in nixpkgs, so it belongs in the shared set rather than a per-machine
imperative install. Add to `home/packages/dev.nix`, alphabetically after `sqlite`:

```nix
    sqlc
```

Then drop the imperative copy so Nix owns it:

```bash
ssh artemis "bash -lc 'rm -f ~/go/bin/sqlc'"
```

`air` is also in `~/go/bin` on both machines but is *already* in `dev.nix`, so
the go-installed copies are redundant shadows — remove those too:

```bash
ssh artemis "bash -lc 'rm -f ~/go/bin/air'"
rm -f ~/go/bin/air
```

- [ ] **Step 4: Verify**

```bash
git add home/packages/dev.nix
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
```
Expected: a store path. After activation, `which sqlc` resolves under
`~/.nix-profile/bin`, not `~/go/bin`.

- [ ] **Step 5: Fix the hardcoded path in the plugin repo**

This is a commit to `~/personal/claude-plugins`, **not** to this flake.
`kmello-skills/skills/managing-homebox/SKILL.md` hardcodes an absolute
`/home/kyle/...` path, so the skill is broken on macOS.

**Ordering dependency:** on ariane this repo does not exist until **Task 11
Step 1** clones it. If Task 14 runs before Task 11, do this step on artemis
instead (where the repo already exists) and note that `sed -i ''` is BSD syntax —
on artemis use `sed -i` with no argument.

```bash
cd ~/personal/claude-plugins
grep -n '/home/kyle' kmello-skills/skills/managing-homebox/SKILL.md
```
Expected: two hits, lines 9 and 16.

Replace both with `~/personal/homebox`, which resolves on both platforms:

```bash
sed -i '' 's#/home/kyle/personal/homebox#~/personal/homebox#g' \
  kmello-skills/skills/managing-homebox/SKILL.md
grep -n 'homebox' kmello-skills/skills/managing-homebox/SKILL.md
git add kmello-skills/skills/managing-homebox/SKILL.md
git commit -m "managing-homebox: use ~/personal/homebox instead of an absolute path

The skill hardcoded /home/kyle/personal/homebox, which does not exist on
macOS. ~ resolves on both hosts."
git push
```

Then pull it on artemis so both machines agree:
```bash
ssh artemis "bash -lc 'git -C ~/personal/claude-plugins pull'"
```

`dev-plugins` was checked and contains no absolute paths — nothing to do there.

- [ ] **Step 6: Commit the flake side**

```bash
git add home/fish.nix home/packages/dev.nix
git commit -m "home: share q.fish and sqlc across both machines

q.fish was hand-written on artemis only and unknown to Nix; it now lives
in home/fish.nix with the platform string injected rather than hardcoded
to NixOS/WSL2. sqlc moves from a go install on artemis into the shared
package set. Redundant go-installed copies of air removed on both."
```

---
# Rollout

Deploy in dependency order. Each is independently revertible with `home-manager switch --rollback` or `nixos-rebuild --rollback`.

```bash
# 1. Hub first — everything else points at it.
ssh gateway "bash -lc 'cd ~/nixosdotfiles && git pull && sudo nixos-rebuild switch --flake .#gateway'"

# 2. artemis.
ssh artemis "bash -lc 'cd ~/nixosdotfiles && git pull && sudo nixos-rebuild switch --flake .#artemis'"

# 3. ariane.
cd ~/nixosdotfiles && git pull && home-manager switch --flake .#ariane
```

## Post-rollout checks

- [ ] `wip` outside a repo lists pending snapshots and missing repos
- [ ] Edit a file on artemis, wait 5 min, `cd` into that repo on ariane → the `⬇` notice appears
- [ ] `git remote -v`, `git branch -a`, and `git log --all` in a work repo are unchanged from before rollout
- [ ] In a scratch repo: `wip pull --force` then `wip undo` restores the previous tree, including untracked files
- [ ] `Ctrl+R` shows the fzf.fish interface with commands from the other machine
- [ ] `Ctrl+T`, `Ctrl+Alt+L`, `Ctrl+Alt+S`, `Ctrl+V`, `Ctrl+Alt+P` still work
- [ ] A file dropped in `~/notes` reaches both other machines
- [ ] `~/.claude/skills` resolves to `~/nixosdotfiles/claude/skills` and is writable
- [ ] `claude plugin disable <x>` on one machine shows as a git modification to `claude/settings.json`; after pull, the other machine agrees
- [ ] `claude doctor` is clean on **both** machines — no missing-marketplace errors
- [ ] `jq '.enabledPlugins | keys | length' ~/.claude/settings.json` is 19 on both
- [ ] `type q` resolves in fish on both machines
- [ ] `which sqlc` resolves under `~/.nix-profile/bin`, not `~/go/bin`
- [ ] `ssh gateway "bash -lc 'sudo -u ci ls /home/kyle'"` fails
- [ ] Adding a package on one machine produces the drift warning on the other

## Deferred

- **gateway is LAN-only, by decision (2026-07-28).** Verified: the routing table
  sends `10.11.12.0/24` over `en0`, and no tailnet node advertises that range
  (`magnesium` → `10.1.0.0/24`, `10.1.1.0/24`, `10.1.2.0/24`; `vpn` →
  `10.20.23.0/24`, `192.168.10–22.0/24`). So ariane reaches the hub on the home
  network or over **UniFi Teleport**, and not otherwise.

  This is accepted rather than fixed, which is why the hub-unreachable path is
  handled explicitly rather than left to chance: `wip_hub_up` probes once per run
  with `ConnectTimeout=3`, `GIT_SSH_COMMAND` bounds git's own SSH at 5s, and both
  batch verbs no-op silently when the hub is away. Crucially `wip pull`, `wip
  diff` and the fish cd-hook all read the local shadow cache, so **the entire
  user-facing surface keeps working offline** — only the background push/fetch
  pauses, and it resumes on the next tick once you are home or on Teleport.

  **Optional future improvement:** put Tailscale on the UniFi UDM (planned), or
  `services.tailscale.enable = true` on gateway itself. Either gives the hub a
  stable `100.x` address reachable from anywhere, at which point point
  `kyle.wip.remoteHost` at the tailnet name and the pauses disappear. Nothing in
  this design needs to change for that — it is a one-line option flip.
- **`services.atuin.openRegistration`** must be flipped to `false` after both clients register (Task 10, Step 5).
- **Shadow-cache pruning** — `~/.cache/wip` grows by one bare repo per repo touched. Bounded by snapshot trees only, no history, so it is small; add a prune to the tick script if it becomes a problem.
- **`~/.config` reconciliation is deferred** by decision (34 entries on artemis
  vs 12 on ariane). Portable candidates worth a later look: `glow`, `lazygit`,
  `lazydocker`, `k9s`, `helm`, `glab-cli`, `jrnl`, `jiratui`, `bkt`, `carapace`,
  `devenv`, `croc`, `doom`/`emacs`. ariane-only: `rclone`, `lvim`, `jgit`.
- **`claude` ownership: RESOLVED 2026-07-28 (commit `5fe2660`).** ariane was
  running a native self-updating build from `~/.local/share/claude` (3 versions,
  959 MB) symlinked into `~/.local/bin`, which shadowed the Nix `claude-code`
  because `~/.local/bin` precedes `~/.nix-profile/bin` on PATH. Removed the
  symlink, the installer's `ClaudeCode.app` wrapper, and the two stale versions
  (714 MB freed); `/Applications/Claude.app` untouched. `claude` now resolves to
  `/nix/store/...claude-code-2.1.220/bin/claude`. `DISABLE_AUTOUPDATER=1` added
  to `home/fish.nix` so the binary cannot reinstall the native build. Also fixed
  `sessionPath` hardcoding `/home/kyle/.local/bin`, a dead entry on macOS.
  **artemis was already correct** (`/etc/profiles/per-user/kyle/bin/claude`) and
  was not rebuilt — it picks up `DISABLE_AUTOUPDATER` on its next switch. Note
  artemis is on claude 2.1.219 vs ariane's 2.1.220, i.e. it has not rebuilt since
  the last `nix flake update` — exactly the drift Task 13 warns about.
- **Homebrew was surveyed and left alone** — see Task 14's preamble. Nix already
  wins PATH, and the apparent duplicates are not duplicates.
- **artemis's 37 repos vs ariane's 22.** `wip clone` surfaces the gap, but cloning all of them onto a work laptop is probably not wanted. Expect to clone selectively.
