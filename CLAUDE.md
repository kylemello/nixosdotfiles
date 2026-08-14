# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal, declarative Nix configuration for multiple machines (NixOS systems + standalone Home Manager profiles), managed as a single flake. Tracks `nixos-unstable`. `allowUnfree` is on.

> The `README.md` predates some refactors and is partly stale (it references `overlays/latest-packages.nix` and `home/common.nix`, which no longer exist, and lists only one machine). When the two disagree, trust this file.

## This repo is PUBLIC

`github.com/kylemello/nixosdotfiles` is a **public** repository. Anything committed here is world-readable and stays in the history after a later deletion. Treat every write as publication.

Before writing, staging, or committing anything:

- **Never commit secrets.** No API keys, tokens, bearer headers, passwords, private keys, `.env` contents, session cookies, or connection strings with credentials. Secrets go in a file outside the repo that Nix *references by path* — the established patterns are `guiPasswordFile = "/var/lib/syncthing/gui-password"` (`hosts/sync-hub.nix`) and the Home Assistant MCP token living only in `~/.claude.json` (`home/claude-code.nix`). Public SSH keys, Syncthing device IDs and hashed-nothing config are fine; their private halves are not.
- **`claude/` and `nvim/` are live working-copy symlink targets, and the tools themselves write into them.** `~/.claude/{settings.json,CLAUDE.md,skills,…}` (`home/claude.nix`) and `~/.config/nvim` (`home/nvim.nix`) are `mkOutOfStoreSymlink`s into this repo, so `/config`, "always allow", `/plugin`, `:Lazy update` and `:LazyExtras` all edit tracked files. A secret Claude Code writes into `settings.json` lands in a public repo without anyone editing a file. **Read the diff of these paths before staging them** — never `git add -A` / `git commit -a` blind.
- **Scan before committing** when the diff touches anything credential-shaped: `gitleaks git --no-banner --redact -v` (history) and `gitleaks dir . --no-banner --redact -v` (working tree, incl. untracked). `gitleaks` is already in `home/packages/dev.nix`. Clean as of 2026-08-14 across 138 commits and the working tree.
- `.claude/settings.local.json` is kept out only by `~/.config/git/ignore`, a hand-made local file that **Home Manager does not manage** — so a fresh clone on another machine has no such guard. Don't rely on it; check `git status` output rather than assuming an ignore rule exists.
- Non-secret but publicly visible recon surface already in here, which is accepted: internal hostnames (`gitea`/`ha`/`mcp`/`lan.kmello.dev`), private IPs, `gateway`'s SSH port 422, Syncthing device IDs, both email addresses, authorized SSH public keys. Don't add *more* of this than a change needs, and don't paste new internal URLs, ticket contents, or work data into comments.
- Anything genuinely secret that reaches a commit is **compromised, not fixable by a follow-up commit**: say so immediately and rotate the credential. History rewriting is the user's call, never a silent cleanup.

## Common commands

```fish
# Apply a NixOS system (run on / for that host). Machines: artemis, atlas, gateway, nixosvm
sudo nixos-rebuild switch --flake .#artemis

# Apply a standalone Home Manager profile (non-NixOS hosts)
home-manager switch --flake .#ariane            # or .#kyle-work

# Update overlay-pinned packages (e.g. infisical) to latest upstream — see "Overlays" below
nix run .#update-overlays

# Update flake inputs (nixpkgs, home-manager, claude-code, catppuccin, ...). Also bumps
# nixpkgs-provided packages like sqlite. Single input: nix flake update <name>
nix flake update

# Fast validity check WITHOUT building — evaluates the whole system to a derivation path.
# Use this to confirm a change is correct before a real rebuild.
nix eval .#nixosConfigurations.artemis.config.system.build.toplevel.drvPath

# Inspect the resolved version of a package (through overlays)
nix eval --raw .#legacyPackages.x86_64-linux.infisical.version
```

There is no test/lint suite; the `nix eval` of `toplevel.drvPath` (or `nix flake check`, which is heavier) is the verification step.

## Architecture

Three composable layers, assembled in `flake.nix`:

- **`hosts/`** — reusable *system* modules ("features"): `common.nix` (base for every NixOS host: nix settings, GC, users, docker, nix-ld), `wsl.nix`, `desktop.nix`, `vm.nix`.
- **`machines/<name>/configuration.nix`** — a concrete NixOS host: sets `networking.hostName`, imports the `hosts/` features it needs, and assigns `home-manager.users.kyle` a profile from `users/`.
- **`users/` + `home/`** — Home Manager (the *user* environment). `users/kyle/*.nix` are entry profiles that import modules from `home/`. Package sets live in `home/packages/{base,dev,misc}.nix`. WSL-specific user tweaks (e.g. `ssh.exe`, 1Password agent) are in `home/wsl.nix`.
- **`claude/` + `nvim/`** — plain (non-Nix) config trees symlinked into `$HOME` from the live working copy by `home/claude.nix` and `home/nvim.nix`. Both are behind `kyle.<name>.enable`, off in `users/kyle/home.nix` and turned on only in `home/wsl.nix` (artemis) and `home/darwin.nix` (ariane) — the two machines that have a checkout to point at. See the public-repo section above before editing them.

`flake.nix` outputs:
- **`nixosConfigurations`** — built via the local `mkNixOS` helper, which applies the `overlays` list, wires the `home-manager` NixOS module (`useGlobalPkgs`/`useUserPackages`, so HM shares the system `pkgs` and overlays), and always includes `nixos-wsl` (`wsl.enable` only turns on where `hosts/wsl.nix` is imported).
- **`homeConfigurations`** — standalone Home Manager profiles (for non-NixOS hosts), produced inside `flake-utils.lib.eachSystem`. Also exposes `legacyPackages` and the `apps.update-overlays` app per system.

The `overlays` list is defined once in `flake.nix` and threaded into **both** NixOS and Home Manager `pkgs`, so any overlay change applies everywhere.

### Machines
| Host | Role |
|------|------|
| `artemis` | WSL daily driver (`hosts/wsl.nix` + `home/wsl.nix`); hostname `artemis` |
| `atlas` | Bare-metal/VM with NVIDIA GPU + nvidia-container-toolkit |
| `gateway` | QEMU guest VM |
| `nixosvm` | Hyper-V desktop VM (Gnome/Wayland, 4K); SSH on port 422 |

Standalone profiles:
| Profile | Role |
|---------|------|
| `kyle-work` | Office remote work machine. Stale — imports a since-removed `home/common.nix`, so it does not evaluate. (A second profile, `kmello@iodine` / `users/kyle/work-kmello.nix`, was removed; the `iodine` SSH host alias in `home/profiles/desktop.nix` stays.) |
| `ariane` | macOS (`aarch64-darwin`) work laptop. **Home Manager only, no nix-darwin** (Homebrew keeps GUI casks; Nix owns the CLI toolchain). Mirrors artemis's user env via `users/kyle/ariane.nix` + `home/darwin.nix` (git signing through the macOS 1Password `op-ssh-sign`; forces fish inside tmux). Built on Determinate Nix. Linux-only pkgs (e.g. `msodbcsql18`) are guarded with `lib.optionals stdenv.isLinux`. |

## Overlays and the auto-update system

`overlays/default.nix` **auto-discovers** every `*.nix` in `overlays/` (except itself) and composes them. To add a package override, drop in `overlays/<name>.nix` as `self: super: { <pkg> = ...; }` — no wiring needed.

**Only overlay packages you need newer than nixpkgs ships, and prefer prebuilt binaries over building from source.** Do NOT override low-level libraries (e.g. `sqlite`) with much newer upstream sources: nixpkgs' build flags drift from upstream's, and since the override is global it breaks the whole closure. (`sqlite` was overlaid and broke on SQLite's new Autosetup `configure` — it was dropped; nixpkgs' `sqlite` already updates via `nix flake update`.)

### Pinned-sources pattern (`infisical`)
Overlays that track a specific upstream release keep their version + hashes in **`overlays/_sources/<name>.json`**; the `.nix` reads it with `builtins.fromJSON`. This means an updater only rewrites JSON, never the Nix code.

An updater is a sibling script **`overlays/<name>.update.sh`** taking the JSON path as `$1`. **`nix run .#update-overlays`** (defined in `flake.nix`) auto-discovers and runs every `*.update.sh`, then `git add`s `overlays/_sources/`. To make a new overlay auto-updating, add its `.nix` (reading `_sources/<name>.json`), an initial JSON, and a `<name>.update.sh`. The infisical updater intentionally picks the latest release that actually has binary assets (newest tags sometimes ship before assets are attached).

### claude-code, always latest
`claude-code` comes from the **`sadjow/claude-code-nix`** flake input (overlay applied in the shared `overlays` list), which refreshes hourly. It is intentionally **NOT** set to `inputs.nixpkgs.follows` so its Cachix-cached prebuilt binaries hit (overriding nixpkgs would force a local rebuild). The `claude-code.cachix.org` substituter + key are in `hosts/common.nix`. It updates with `nix flake update`.

### Full "update everything" workflow
`./update.sh` (repo root) runs all three steps; it targets the current hostname on NixOS
or takes a profile/host arg, and accepts `--no-switch` to update without rebuilding:
```fish
./update.sh                    # update overlays + inputs, then rebuild this host
./update.sh ariane             # ...and activate a standalone Home Manager profile instead
```
Equivalent manual steps:
```fish
nix run .#update-overlays      # overlay-pinned pkgs (infisical, ...)
nix flake update               # flake inputs (nixpkgs, claude-code, sqlite-via-nixpkgs, ...)
sudo nixos-rebuild switch --flake .#artemis
```

## Gotchas

- **Flakes only see git-tracked files.** After creating any new file the build reads (a new overlay, a `_sources/*.json`), `git add` it or `nix` eval/build won't find it. (`update-overlays` stages `_sources/` for you.)
- `overlays/*.update.sh` rely on `nix store prefetch-file --json` (returns SRI hashes) plus `curl`/`jq`; `update-overlays` provides these on `PATH` and uses ambient `nix`.
- Avoid `writeShellApplication` for helper scripts here — it pulls `shellcheck` (a heavy, often-uncached Haskell build). Use `writeShellScriptBin` and set `PATH`/`set -euo pipefail` manually (see `apps.update-overlays`).
