# `wip` — moving uncommitted work between machines

Hands work-in-progress between artemis and ariane via bare repos on `gateway`.
Companion: [`cross-machine-sync.md`](cross-machine-sync.md) for the wider system.

## What it is, and is not

**Is:** a way to pick up an uncommitted working tree on the other machine.

**Is not:** a git replacement. It never commits, never pushes to your remotes,
never touches your branches. Committed work still travels by `git push`/`pull`.

**It never modifies your repository.** No added remotes, no added refs, no
touched `HEAD`, index, or working tree. That is the one hard requirement the
design exists to satisfy, and 214 assertions enforce it. The single exception is
`wip pull`, which is the whole point of `wip pull` — and it saves your previous
state first.

## Commands

```
wip           in a repo → what's waiting here
              elsewhere → every repo with something waiting, plus hub staleness

wip diff      preview the incoming changes
wip pull      apply them to your working tree
wip undo      reverse the last pull
wip clone     fetch repos that exist on only one machine
wip push      snapshot now (the timer does this every 5 min anyway)
wip forget    retire a repo's hub snapshot and local caches (run `--list` first)
```

Every verb derives its repo from `$PWD`. No host argument, and no repo argument
either — except `wip forget`, which usually has no repo left to derive from.

## Normal use

You don't run anything. A timer snapshots dirty repos every 5 minutes. On the
other machine, `cd` into the repo and it tells you:

```
⬇  snapshot from artemis · 14 min ago · 3 files, +47 −12 · run `wip pull`
```

## Read the notice carefully — there are three of them

A snapshot records the commit it was taken on top of. `wip` classifies that
against your local `HEAD` and says something different in each case:

```
⬇  … · 3 files, +47 −12 · run `wip pull`
   You have the base. Straightforward.

⬇  … · based on a1b2c3d, which you do not have — run `git pull` first, then `wip pull`
   The other machine has commits you don't. Get them, THEN take the
   uncommitted work layered on top. Usually both, in that order.

⬇  … · base a1b2c3d is unknown here — run `git fetch` first
   You cannot see that commit at all. It may not have been pushed anywhere.
   `wip pull` refuses outright here.
```

The middle case is the common trap. Before this existed, `~/personal/Tautulli`
reported *"1189 files changed, +15580 −230346 · run `wip pull`"* — the machines
were 8 months apart and the right answer was `git fetch`.

## Why folder names don't matter

Repos pair by **normalised origin URL**, not directory name. These are one repo:

```
artemis: ~/work/pdpm.navigator.mobile   ↔   ariane: ~/work/pdpm-navigator-expo
artemis: ~/work/census.navigator.mobile ↔   ariane: ~/work/med-a-navigator
```

11 repos pair by origin; only 9 would pair by name. Never rename anything to
make it work — and note that renaming a *GitHub repo* WOULD break pairing,
because the origin URL is the identity.

## What moves and what doesn't

Moves: tracked modifications, untracked files git would add.

Doesn't: anything in `.gitignore` — `node_modules`, `.venv`, `target`, `dist`.
About 13 GB of it. Those are arch-specific anyway (artemis x86_64 Linux, ariane
aarch64 Darwin) and must be rebuilt per machine. You still `pnpm install` once
per machine per repo, as you already do.

## Safety

`wip pull` overwrites your working tree. Protections, in order:

1. Refuses if your tree is dirty, unless `--force`.
2. Refuses if the snapshot's base is unknown to you, unless `--force`.
3. Warns and asks for confirmation if the base is ahead of you.
4. Saves your current tree to `refs/wip-safety/pre-pull` **before** touching
   anything — and refuses to proceed if that save fails.
5. Shows the diff and asks.

`wip undo` restores from step 4.

The safety ref lives in `refs/wip-safety/`, not `refs/wip/`, because
`fetch --prune` on `refs/wip/*` was deleting it — so `wip undo` used to stop
working within 5 minutes of any pull.

## Retiring a repo — `wip forget`

Deleting a repo locally stops its snapshots (the tool only walks what exists)
and drops it from the manifest on the next tick. Three things are left behind,
and until this verb existed nothing ever collected them:

```
gateway:/home/kyle/wip/<slug>.git          the bare snapshot repo
~/.cache/wip/<slug>.git                    the local shadow cache
~/.local/state/wip/<slug>.{tree,created}   the markers
```

```
wip forget --list     what has accumulated; changes nothing
wip forget <slug>     retire one — the usual form, since the folder is gone
wip forget            in a repo: retire this one
```

`--list` cross-references the hub's `*.git` against **both** machines'
manifests *and* the repos actually on this disk, and names what matches
nothing. On 2026-07-28 that was 3 of 23. The local walk is not redundant with
our own manifest: that manifest is only as fresh as the last tick that reached
the hub, and it omits any repo whose `git status` failed — either gap would
show a repo sitting right here as deletable.

An argument may be a slug, a path or an origin URL; all three normalise the same
way `wip_slug` does. A path to a *live* repo is resolved through its origin, not
its name. Anything that normalises to a slug the hub has never held is reported
as such rather than guessed at.

Three things it tells you, each of which matters more than the deletion:

**It refuses when the other machine still has the repo.** That machine's next
tick would recreate the hub repo within five minutes, so deleting achieves
nothing. Delete the repo there first. `--force` overrides.

**It warns when the hub repo still holds a snapshot.** Once *both* machines have
deleted the repo, the hub's bare repo is the only copy of that uncommitted work
— nothing was committed, no shadow cache is refreshed for it, and `wip undo`
cannot reach it. Deleting is final. All three orphans found on 2026-07-28 were
in exactly this state, each holding a snapshot four hours old.

**It cannot reach the other machine.** It cleans this machine's cache and
markers and the hub's bare repo. The other machine's cache and markers are its
own; run `wip forget <slug>` there too. It says so every time.

It never touches the repository itself, even run from inside one.

### Orphans nobody created by deleting anything

The slug *is* the identity, so anything that changes the slug orphans the old
one on the spot while the repo carries on working normally:

- **the origin URL changes** — one of the three orphans found on 2026-07-28 was
  this, a repo moved from `github.com/lakr233/…` to `gitea.kmello.dev/kylemello/…`,
  leaving `github-com-lakr233-gitlab-license-generator.git` behind holding its
  last pre-move snapshot;
- **an origin-less repo moves directory**, since its slug is the path.

Same mechanism as the rename warning under "Why folder names don't matter" —
and the reason `--list` is worth running occasionally even when you have not
deleted anything.

---

# Troubleshooting

## Nothing is syncing

```bash
wip                      # reports how long since the hub was last reached
```

Silence with a recent hub contact is normal — nothing is dirty. A stale
timestamp means the hub is unreachable, which off-network is expected.

```bash
ssh gateway 'echo ok'                          # is the hub up?
systemctl --user status wip.timer              # artemis
launchctl list | grep home.wip                 # ariane
tail -20 ~/.local/state/wip/agent.log          # ariane's tick log
journalctl --user -u wip -n 40                 # artemis's
```

## `wip` prompts for 1Password

It shouldn't — that was the bug that produced ~290 authorizations an hour.
Check the dedicated key is being used:

```bash
SSH_AUTH_SOCK= ssh -i ~/.ssh/wip_hub_ed25519 -o IdentitiesOnly=yes gateway 'echo ok'
```

If that works but `wip` still prompts, something is reaching the agent — look
for a call missing `-o IdentitiesOnly=yes`, or `kyle.wip.driftCheck` being back
on (its `git fetch` of this repo goes to GitHub over SSH).

## `Permission denied` from the hub

Usually a fresh machine with no hub key:

```bash
ssh-keygen -t ed25519 -N '' -C "wip-hub@$(hostname)" -f ~/.ssh/wip_hub_ed25519
cat ~/.ssh/wip_hub_ed25519.pub      # add to machines/gateway/configuration.nix
```

Then rebuild gateway. The private half never enters git.

## A repo never appears on the other machine

```bash
wip clone       # lists repos the other machine has and you don't
```

If it should be paired but isn't, the origins probably differ:

```bash
git -C <repo> remote get-url origin        # compare on both machines
```

Different origin means different slug means no pairing. Repos with **no**
origin fall back to a path-based slug, so they only pair if the paths match.

## `wip pull` refuses

Read which of the three refusals it is — dirty tree, unknown base, or base
ahead. Each names its own fix. `--force` bypasses the first two but not the
confirmation on the third.

## `wip undo` says there's no snapshot

The safety ref only exists after a `wip pull` in that repo. It is per-repo and
overwritten by each pull — it recovers the *last* pull, not a history.

## Diagnosing by hand

```bash
# what the hub holds, and what on it no longer matches a repo on either machine
wip forget --list
ssh gateway 'cat /home/kyle/wip/_manifest/artemis.tsv'   # slug|url|path|dirty|head

# this repo's slug and shadow cache
git -C <repo> remote get-url origin
ls ~/.cache/wip/

# the tests
nix shell nixpkgs#coreutils nixpkgs#git -c bash tests/wip.test.sh
```

Run the suite under `nix shell` — `wip.sh` uses `date -Iseconds`, which BSD
`date` on macOS does not support.

## Failure modes seen during the build

Each of these shipped at some point and was caught. If behaviour looks strange,
these are the shapes it took:

| Symptom | Cause |
|---|---|
| Timer runs forever, does nothing, logs nothing | `wip_hub_up` classified a failure as "hub asleep". Hit three separate times — exit 127 (missing binary), 126 (unexecutable), 255 (auth failure). Now only 255-with-a-connection-error is quiet. |
| `wip pull` claims "previous tree saved" when it wasn't | The safety ref failed and the destructive checkout ran anyway. Now gated. |
| `wip undo` stops working ~5 min after a pull | `fetch --prune` deleted the safety ref. Moved out of the pruned namespace. |
| A snapshot silently replaced by an empty tree | `write-tree` returns the empty-tree hash on a broken temp index rather than erroring. Now checked. |
| Enormous bogus diffstat, "run `wip pull`" | Base commit ignored. Now classified three ways. |
| `.git/index` modified every 5 minutes | `git status` writes the index when the stat cache is stale. Now `--no-optional-locks`. |

The recurring theme is **silent failure**: a background timer nobody watches,
reporting success. When something seems off, check the logs and the hub
staleness stamp before assuming it's working.
