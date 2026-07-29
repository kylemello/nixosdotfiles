# Cross-machine sync — what exists and how to check it

Built 2026-07-28. This describes the system as deployed, the diagnostic command
for each part, and the failure modes actually hit during the build. It is
written for the case where something breaks months from now and the reasoning
has been forgotten.

Companion document: [`wip.md`](wip.md) — the repo-sync tool specifically.

## Topology

```
   artemis (NixOS on WSL, x86_64)              ariane (macOS, aarch64)
   home desktop                                work laptop
        │                                              │
        │            ┌────────────────────┐            │
        └───────────▶│      gateway       │◀───────────┘
                     │  Proxmox VM, 24/7  │
                     │  ────────────────  │
                     │  /home/kyle/wip/   │  bare snapshot repos
                     │  syncthing :22000  │  ~/notes, ~/scratch
                     │  atuin     :8888   │  shell history
                     └────────────────────┘
```

`gateway` is the hub so neither laptop needs the other awake. It is reachable
**only from the home LAN or over UniFi Teleport** — no tailnet route covers
`10.11.12.0/24`. Being off-network is normal, not an error, and everything
degrades to "pauses and resumes later".

## The five layers

| Layer | Mechanism | Config |
|---|---|---|
| Config | Nix flake | the whole repo |
| Uncommitted work | `wip` → bare repos on gateway | `home/wip.nix`, `home/wip/` |
| Loose files | Syncthing via gateway | `home/sync.nix`, `hosts/sync-hub.nix` |
| Claude config | live symlinks into this repo | `home/claude.nix`, `claude/` |
| Shell history | self-hosted Atuin | `home/atuin.nix` |

Repos deliberately do **not** go through Syncthing. An earlier hand-rolled
attempt to sync `~/work` that way failed on `.git` conflicts; `wip` exists
because of that.

---

## Layer: uncommitted work (`wip`)

See [`wip.md`](wip.md). One-line check:

```bash
wip          # in a repo: what's waiting; elsewhere: everything, plus hub staleness
```

## Layer: loose files (Syncthing)

Scope is deliberately small — `~/notes` and `~/scratch` only.

```bash
# does this machine see the hub?
curl -s -H "X-API-Key: $(grep -o '<apikey>[^<]*' \
  "$HOME/Library/Application Support/Syncthing/config.xml" | head -1 | cut -d'>' -f2)" \
  http://127.0.0.1:8384/rest/system/connections | jq '.connections'
```

Config dirs differ per host and are **not** `~/.config/syncthing` on the HM
machines:

| host | path |
|---|---|
| ariane | `~/Library/Application Support/Syncthing` |
| artemis | `~/.local/state/syncthing` |
| gateway | `~/.config/syncthing` (set explicitly in `hosts/sync-hub.nix`) |

**`overrideDevices`/`overrideFolders` are `true`.** Anything paired by hand in
the GUI is deleted on the next activation. Declare it in `sync-devices.nix`
instead.

**Do not delete a Syncthing config directory.** The device IDs in
`sync-devices.nix` *are* the TLS identities stored there. Deleting regenerates
them, the committed IDs become wrong, and the machines silently never connect.

### Failure hit during the build

First activation on ariane appeared to do nothing. Cause: Syncthing 2.x
migrates its v1 database to SQLite on first start and serves only a *temporary*
API while doing so. `syncthing-init` raced it, got five `curl: (7)` failures,
and died — so the declarative config was never applied and the old config kept
running. One-time; fixed by re-running init afterwards:

```bash
launchctl kickstart -k "gui/$(id -u)/org.nix-community.home.syncthing-init"   # ariane
```

The GUI is on `:8384` with auth. The password file must be **owned by the
syncthing user**, not root — `syncthing-init` runs as `kyle`, and a root-owned
file fails with `Permission denied` and silently leaves no `<password>` element
at all, locking everyone out including you.

## Layer: Claude config

`~/.claude/{CLAUDE.md,skills,agents,commands,settings.json,settings.local.json}`
are `mkOutOfStoreSymlink`s into `claude/` in this repo. They stay **writable**,
so `/config`, `/plugin` and hand-edits all work, and changes land in git.

```bash
readlink -f ~/.claude/settings.json    # must end in nixosdotfiles/claude/…
```

Sync is **git, not a daemon**. Edit → commit → push → pull on the other machine.

`settings.local.json` is per-host (`claude/local/<host>.json`) because
`extraKnownMarketplaces` holds absolute paths that differ.

Deliberately never synced: `projects/`, `history.jsonl`, `.credentials.json`,
and the caches. Secrets do not ride along with config.

### The "declared ≠ done" trap

Sharing `settings.json` shares *intent*, not runtime state. Claude Code keeps a
separate live registry it alone writes:

```
settings.json          enabledPlugins        ← declarative, synced
known_marketplaces.json                      ← live, NOT synced
installed_plugins.json                       ← live, NOT synced
```

A new machine therefore needs a one-time bootstrap, or plugins show as
enabled-but-absent:

```bash
claude plugin marketplace add ~/personal/claude-plugins
claude plugin marketplace add ~/work/claude-plugins
claude plugin install kmello-skills@kmello
claude plugin install work-os@kmello-dev
claude plugin install aegis-jira@kmello-dev
```

Note the three-way naming asymmetry, all deliberate: folder `claude-plugins`,
GitHub repo `dev-plugins`, marketplace `kmello-dev`. The repo name is *not*
renamed because `wip` derives its slug from the origin URL — renaming would
un-pair the machines' snapshots.

MCP servers are declared in `home/claude-code.nix` and merged into
`~/.claude.json` with `jq '. * $d'` — the file is Claude's, so the module adds
keys and never removes them. **Declaring less does not retract what is already
there**; removing a server needs a manual edit too.

## Layer: shell history (Atuin)

Server on gateway `:8888`; clients push/pull encrypted records.

```bash
atuin status                      # last sync, server, username
sqlite3 ~/.local/share/atuin/history.db 'select distinct hostname from history'
```

Two things must both be true: same account, and **same encryption key**
(`~/.local/share/atuin/key`, compare hashes across machines). Different keys
produce a sync that reports success and shows nothing.

### Failure hit during the build

`atuin sync` needs `$ATUIN_SESSION`, which only exists **inside an interactive
shell** where atuin's hook has run. Run from SSH or a script it dies at a
one-time store migration:

```
29 in history index, but 28 in history store
Error: Failed to find $ATUIN_SESSION in the environment.
```

Fix: run `atuin sync -f` in a real terminal. One-time.

---

## SSH: two credentials, on purpose

| Purpose | Credential | Why |
|---|---|---|
| GitHub, commit signing | 1Password agent | interactive, should prompt |
| `wip` → gateway | `~/.ssh/wip_hub_ed25519` | unattended, must never prompt |

The hub key is passed with `-i … -o IdentitiesOnly=yes`. **`IdentitiesOnly` is
load-bearing** — without it ssh offers agent keys first and the prompts return.
Public halves live in `machines/gateway/configuration.nix`; private halves never
enter git.

This split exists because `wip fetch` originally opened one SSH connection *per
repo* — roughly 24 authorizations every 5 minutes, ~290/hour, per machine. The
fix was three parts: the dedicated key, `ControlMaster` multiplexing (impossible
through Windows OpenSSH, which is why artemis stopped using `ssh.exe` for the
hub), and gating fetch on the other host's manifest.

`kyle.wip.driftCheck = false` on both hosts for the same reason: the tick's
`git fetch` of this repo goes to GitHub over SSH and hit the agent every 5
minutes. Consequence: the drift alarm only catches "you have commits this
machine hasn't switched to", not "the other machine pushed something".

**The keys are imperative state Nix depends on.** A rebuilt machine has no key
and `wip` fails with `Permission denied` until you generate one and add its
public half to gateway. A private key cannot live in a public repo; `sops-nix`
or `agenix` is the real fix and is not done.

## Host quirks worth remembering

- **`users/kyle/home.nix` is imported by all four NixOS hosts** — artemis, atlas,
  gateway, nixosvm. Import modules there; enable them only in `home/wsl.nix` and
  `home/darwin.nix`. Enabling in the shared profile once would have given gateway
  a second Syncthing that reconfigured the hub, with eval *and* rebuild reporting
  success.
- Verify against a host that sets nothing: `nix eval
  .#nixosConfigurations.atlas.config.system.build.toplevel.drvPath`. If atlas
  changes, something leaked.
- Every option needs a `default`. One without is a hard eval error on hosts that
  never set it.
- **`home.sessionPath` reaches interactive shells only** — never systemd user
  units or launchd agents. Anything a daemon runs needs absolute store paths.
- artemis's login shell is fish: `ssh artemis "bash -lc '…'"`. `python3` is not
  on its non-interactive PATH; use `jq`.
- `git log --format=%G?` prints `N` for every commit here because
  `gpg.ssh.allowedSignersFile` is unset. That means *cannot verify*, not
  *unsigned* — check with `git cat-file commit <sha> | grep '^gpgsig'`.

## Verification sweep

```bash
for h in artemis atlas gateway nixosvm; do
  nix eval .#nixosConfigurations.$h.config.system.build.toplevel.drvPath
done
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
nix shell nixpkgs#coreutils nixpkgs#git -c bash tests/wip.test.sh   # 214 passed
```

## Known gaps

- Hub keys are imperative; a fresh machine needs manual bootstrap.
- Plugin install state does not sync (see "declared ≠ done").
- Drift alarm cannot see the other machine's pushes (`driftCheck` off).
- `wip`'s test suite runs `set -uo pipefail` while the shipped binary runs
  `set -euo pipefail`, so the suite does not validate the exact mode the binary
  uses.
- `base=` in snapshot messages is a *short* sha; a prefix ambiguous in the
  reading repo is reported as "unknown base". Conservative, but a full sha would
  be better.

## Escape hatch

Tag `pre-sync` marks the last commit before any of this. Nix generations roll
back per machine. `~/.claude` archives from before the change are on
`truenas_admin@truenas:~/escape-hatch/` (boot-pool — not archival storage).
