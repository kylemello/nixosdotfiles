{ config, lib, pkgs, ... }:

let
  cfg = config.kyle.wip;

  # Resolved once, here, and used by the wrapper, the launchd log paths and the
  # activation dir alike — see the wrapper's comment on WIP_CACHE for why these
  # must not be a shell ''${XDG_STATE_HOME:-…} fallback.
  stateDir = "${config.xdg.stateHome}/wip";
  cacheDir = "${config.xdg.cacheHome}/wip";

  # --- one SSH connection per tick ------------------------------------------
  #
  # Socket for OpenSSH connection multiplexing. `%C` (a hash of
  # local-host/host/port/user) rather than `%h/%p/%r`, for one reason: LENGTH.
  # ssh copies this path into a sockaddr_un, whose sun_path is 104 bytes on
  # macOS (108 on Linux), and before binding the real path it first binds
  # "<path>.XXXXXXXXXXXX" -- 13 more characters. Over the limit, ssh dies with
  # "ControlPath too long for Unix domain socket" and exit 255, which
  # wip_hub_up cannot tell from a sleeping hub: every hub operation would fail
  # silently, forever. Measured with OpenSSH 10.2 on 2026-07-28:
  #
  #   ariane   /Users/kyle/.local/state/wip/cm-<40 hex>   72 chars, 85 with the
  #                                                       temp suffix (cap 103)
  #   artemis  /home/kyle/.local/state/wip/cm-<40 hex>    71 chars, 84
  #
  # %C is a SHA-1 hex digest, so it is 40 characters on every host and this
  # arithmetic does not drift. The assertion below pins it anyway, because the
  # failure it guards against is invisible at runtime.
  controlPath = "${stateDir}/cm-%C";
  # `- 2 + 40`: the literal "%C" in the Nix string becomes 40 hex characters.
  controlPathLen = (lib.stringLength controlPath) - 2 + 40;

  # Options carried by every connection to the HUB -- this file's GIT_SSH_COMMAND
  # and, through WIP_SSH_IDENTITY/WIP_SSH_CONTROL below, wip_hub_ssh's direct ssh
  # calls in home/wip/wip.sh. The two must agree or the tick opens two
  # connections instead of one.
  #
  # NOT applied to the drift fetch further down: that one talks to GitHub, which
  # has never heard of this key.
  hubSshOpts = lib.concatStringsSep " " [
    "-i ${cfg.identityFile}"
    # Load-bearing. ariane's ~/.ssh/config sets IdentityAgent for `Host *`, so
    # without this ssh offers the 1Password agent's keys BEFORE the -i one, the
    # agent signs, and the approval prompt this whole change exists to remove
    # comes straight back.
    "-o IdentitiesOnly=yes"
    # IdentitiesOnly is NOT enough on its own, which cost us intermittent
    # approval prompts long after the dedicated key landed. IdentityFile is
    # CUMULATIVE in ssh_config -- entries append to a list, they do not
    # first-win -- and ariane's ~/.ssh/config includes 1Password's generated
    # ~/.ssh/1Password/config, which carries:
    #
    #   Match Host gateway
    #     IdentityFile ~/.ssh/1Password/SHA256_PoAO….pub
    #
    # So the effective list is [wip_hub_ed25519, <1Password gateway key>], and
    # IdentitiesOnly=yes happily permits BOTH -- it only bars agent keys absent
    # from the list. Confirm with:
    #   ssh -G -i ~/.ssh/wip_hub_ed25519 -o IdentitiesOnly=yes gateway | grep -i identity
    #
    # The on-disk key is offered first and normally wins, which is why this
    # stayed hidden: only when that first attempt lost the connection (gateway
    # rebooting, wifi dropping -- `Connection reset by 10.11.12.105 port 22` in
    # ~/.local/state/wip/agent.log) did ssh fall through to entry two, hit the
    # agent, and prompt. Every five minutes, but only sometimes.
    #
    # Cutting the agent off the hub path entirely makes the fallback
    # unreachable: entry two is a bare .pub whose private half exists only
    # inside 1Password, so with no agent ssh cannot sign with it and fails
    # loudly in agent.log instead of raising a dialog. GitHub and commit
    # signing are untouched -- they do not go through hubSshOpts.
    "-o IdentityAgent=none"
    "-o ControlMaster=auto"
    "-o ControlPath=${controlPath}"
    "-o ControlPersist=60"
  ];

  # The ssh binary this host's `git` already uses for GitHub. NOT cfg.sshCommand:
  # `wip` talks to the hub, the drift check below talks to GitHub, and since the
  # hub moved to a dedicated on-disk key those are two different destinations
  # with two different credentials. On artemis GitHub is still reached through
  # `ssh.exe` and the Windows 1Password agent (home/wsl.nix sets
  # programs.git.settings.core.sshCommand); verified working from the systemd
  # timer on 2026-07-28, so pointing the drift fetch at Nix's openssh instead
  # would break a thing that currently works.
  gitSshCommand =
    lib.attrByPath [ "core" "sshCommand" ] "${pkgs.openssh}/bin/ssh"
      config.programs.git.settings;

  # The script is assembled rather than templated so home/wip/*.sh stay
  # directly testable (see tests/wip.test.sh).
  wip = pkgs.writeShellScriptBin "wip" ''
    set -euo pipefail
    # config.home.sessionPath is appended because this script runs in contexts
    # that never source hm-session-vars.sh — above all the systemd user timer,
    # whose unit has no Environment=PATH. `wip`'s own ssh is now an absolute
    # store path on both machines, but the drift fetch below still runs artemis's
    # `ssh.exe`: a bare command name living under /mnt/c/…/OpenSSH/, and
    # hosts/wsl.nix sets wsl.interop.includePath = false, so home.sessionPath is
    # its ONLY source. Without this the timer resolves nothing, wip_hub_up reads
    # the shell's 127 as "hub away", and the timer pushes nothing and logs
    # nothing every 5 minutes — while `wip push` typed by hand still works,
    # because an interactive shell does have the directory.
    export PATH="${lib.concatStringsSep ":" (
      [ (lib.makeBinPath (with pkgs; [ git openssh coreutils findutils gnused ])) ]
      ++ config.home.sessionPath
    )}:$PATH"

    export WIP_HOST=${lib.escapeShellArg cfg.host}
    export WIP_REMOTE_HOST=${lib.escapeShellArg cfg.remoteHost}
    export WIP_REMOTE_PATH=${lib.escapeShellArg cfg.remotePath}
    export WIP_ROOTS=${lib.escapeShellArg (lib.concatStringsSep " " cfg.roots)}
    # Pinned, not left ambient: this is the one contract variable wip.sh reads
    # with a bare-environment fallback, and its own comment explains the cost of
    # getting it wrong — artemis's $HOME is /home/kyle and WIP_REMOTE_PATH is
    # /home/kyle/wip, so a stray WIP_LOCAL_HUB=1 would make artemis snapshot to
    # itself instead of gateway, with nothing surfacing the mistake. 0 = real
    # ssh hub; only tests/wip.test.sh sets 1.
    export WIP_LOCAL_HUB=0
    # Resolved HERE, from the Nix layer, rather than with a shell
    # ''${XDG_CACHE_HOME:-$HOME/.cache} fallback: the timer (Task 7) names the
    # very same directories in its activation script and launchd log paths, and
    # it cannot read a shell fallback. If XDG_STATE_HOME/XDG_CACHE_HOME were ever
    # exported, a fallback here would silently point `wip` at one pair of
    # directories and the timer at another.
    export WIP_CACHE=${lib.escapeShellArg cacheDir}
    export WIP_STATE=${lib.escapeShellArg stateDir}

    export WIP_SSH=${lib.escapeShellArg cfg.sshCommand}
    # Consumed by wip_hub_ssh in home/wip/wip.sh. Set HERE rather than derived
    # in the shell so that these and GIT_SSH_COMMAND below cannot drift apart:
    # if git multiplexes onto a different socket than the direct ssh calls, the
    # tick quietly opens two connections instead of one.
    export WIP_SSH_IDENTITY=${lib.escapeShellArg cfg.identityFile}
    export WIP_SSH_CONTROL=${lib.escapeShellArg controlPath}

    # Bound git's SSH too, not just wip_hub_up's probe — the hub is LAN-only,
    # so a push attempt from off-network must fail fast rather than block.
    # GIT_SSH_COMMAND OVERRIDES core.sshCommand, which is the point: git's own
    # ssh config is aimed at GitHub, and the hub now has its own key.
    #
    # Not escapeShellArg'd as a whole and not quotable: git SHELL-PARSES this
    # value, so the options have to arrive as separate words. That also means no
    # path in it may contain a space — both are Nix store / $HOME paths.
    export GIT_SSH_COMMAND="$WIP_SSH ${hubSshOpts} -o BatchMode=yes -o ConnectTimeout=5"

    source ${./wip/wip.sh}
    source ${./wip/main.sh}
  '';

  # Prefix, not a ":"-joined list: an EMPTY home.sessionPath must expand to
  # nothing at all. `PATH=":$PATH"` has an empty first entry, which POSIX shells
  # read as "." — the current directory on the PATH of a background job.
  #
  # Interpolated inside shell DOUBLE quotes at the use site, never
  # escapeShellArg'd: HM's sessionPath entries are shell fragments, not literal
  # paths — every host here has `$HOME/.pnpm` and friends in the list, and
  # single-quoting would put a directory literally named `$HOME` on PATH.
  # Double quotes also cover the entries with spaces (`/mnt/c/Program Files/…`).
  # This is the same treatment the wip wrapper above gives them.
  sessionPathPrefix = lib.concatMapStrings (p: "${p}:") config.home.sessionPath;

  # What the timer actually runs. Every command is an absolute store path, with
  # one deliberate exception (gitSshCommand — see the drift block below).
  tick = pkgs.writeShellScript "wip-tick" ''
    set -uo pipefail

    # Deliberately no `|| true` in here. A silent tick is the failure mode this
    # module is written against: nobody watches a five-minute timer, so whatever
    # goes wrong has to reach the journal (systemd) or agent.log (launchd).
    #
    # Both verbs already return 0 for the expected non-events — the hub being
    # off-LAN, one repo in a strange state (see wip_cmd_push in home/wip/main.sh)
    # — so a non-zero status here is a real fault, and worth failing the unit
    # over: `systemctl --user status wip` then shows it without anyone grepping.
    rc=0
    ${wip}/bin/wip push --all || { rc=$?; printf 'wip-tick: push --all failed (exit %s)\n' "$rc" >&2; }
    ${wip}/bin/wip fetch      || { rc=$?; printf 'wip-tick: fetch failed (exit %s)\n' "$rc" >&2; }
    ${lib.optionalString cfg.driftCheck ''
      # Fetch the flake repo too, so home/drift.nix can compare against @{u}.
      # Two things this must not inherit from a login shell, because a timer
      # has neither:
      #
      # 1. The ssh BINARY. On artemis git reaches GitHub through
      #    core.sshCommand = "ssh.exe" (home/wsl.nix) — the keys live in the
      #    Windows 1Password agent. GIT_SSH_COMMAND OVERRIDES core.sshCommand,
      #    so this restates it via gitSshCommand; hardcoding pkgs.openssh here
      #    would bypass that agent and fail auth on every single tick.
      #    BatchMode/ConnectTimeout match the wrapper's, so an off-LAN or
      #    key-less run fails fast instead of hanging.
      #
      #    This is gitSshCommand and NOT cfg.sshCommand, and none of the hub's
      #    -i/ControlPath options come along: since the hub moved to a dedicated
      #    on-disk key those are two destinations with two credentials, and
      #    offering GitHub a key it has never seen — with IdentitiesOnly=yes
      #    suppressing the one that works — would fail auth on every tick.
      # 2. Its PATH. `ssh.exe` is a BARE NAME, resolvable only through
      #    home.sessionPath — which feeds hm-session-vars.sh, i.e. interactive
      #    and login shells only, never a systemd user unit or a launchd agent.
      #
      # Reported but NOT folded into rc: a laptop being off-network is normal,
      # and a unit permanently in `failed` for a reason nobody can act on is
      # just noise that trains you to ignore it.
      PATH="${sessionPathPrefix}$PATH" \
      GIT_SSH_COMMAND=${lib.escapeShellArg "${gitSshCommand} -o BatchMode=yes -o ConnectTimeout=5"} \
        ${pkgs.git}/bin/git -C "$HOME/nixosdotfiles" fetch --quiet \
        || printf 'wip-tick: drift fetch of ~/nixosdotfiles failed (exit %s)\n' "$?" >&2
    ''}
    exit "$rc"
  '';
in
{
  options.kyle.wip = {
    enable = lib.mkEnableOption "cross-machine working-tree snapshots";

    host = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        This machine's logical name. Baked in at build time rather than read
        from `hostname` — ariane's real hostname is `kyles-macbook-pro`, which
        would produce confusing ref names. Empty means this host does not
        participate; the assertion below rejects an empty value when enabled,
        so a misconfiguration fails loudly instead of producing refs named
        `wip/`.
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

    driftCheck = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Also fetch the flake repo each tick, for home/drift.nix. Uses
        `sshCommand`, so it authenticates exactly the way this host's `git`
        already does; a failure is printed to stderr (journal / agent.log) but
        does not fail the unit, since being off-network is normal.
      '';
    };

    sshCommand = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.openssh}/bin/ssh";
      description = ''
        The ssh binary `wip` uses to reach THE HUB, for both `git push` and
        `wip_hub_up`.

        Both machines leave this at Nix's openssh, and artemis in particular
        must NOT be pointed back at `ssh.exe`. It used to be, because the hub
        was reached with the Windows-side 1Password agent's key — but Windows
        OpenSSH implements no ControlMaster at all, so multiplexing (the thing
        that turns ~36 authentications a tick into one) is simply unavailable
        through it. The hub is now reached with `identityFile` instead, which
        removes the reason the override existed.

        Note this is the HUB's ssh only. GitHub is a different destination with
        a different credential; the drift fetch uses `git`'s own
        core.sshCommand, which on artemis is still `ssh.exe`.

        Three constraints on the value:

        1. OpenSSH-CLI-compatible: `wip_hub_ssh` prepends `-i … -o
           IdentitiesOnly=yes -o ControlMaster=auto -o ControlPath=… -o
           ControlPersist=60`, `wip_hub_up` appends `-o BatchMode=yes -o
           ConnectTimeout=3 -o StrictHostKeyChecking=accept-new`, and
           GIT_SSH_COMMAND appends `-o BatchMode=yes -o ConnectTimeout=5`.
        2. A bare binary, NO arguments. git shell-parses GIT_SSH_COMMAND, but
           wip.sh invokes "''${WIP_SSH:-ssh}" as a single quoted word — so a
           value with flags in it would work in git and break every direct ssh
           call site.
        3. Resolvable from a NON-INTERACTIVE PATH. The timer is a systemd user
           unit with no Environment=PATH, so it never sees hm-session-vars.sh.
           An absolute store path (the default) is always safe.
      '';
    };

    identityFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.ssh/wip_hub_ed25519";
      description = ''
        Private key used for EVERY hub connection, passed as `-i` together with
        `IdentitiesOnly=yes`.

        A dedicated on-disk key, deliberately not the 1Password agent. Two
        machines syncing on a five-minute timer should not authenticate with a
        credential whose whole purpose is to ask a human for approval: with one
        connection per repo that was ~36 approval prompts a tick on artemis and
        ~23 on ariane, which is why both timers were stopped.

        `IdentitiesOnly=yes` is not optional. ariane's ~/.ssh/config sets
        `IdentityAgent` under `Host *`, so ssh would otherwise offer the agent's
        keys first, the agent would sign, and the prompt would be back despite
        the `-i`.

        The keypair is NOT generated by Nix — it is a secret, and this repo is
        public. Create it per machine and authorise the public halves on the hub
        (machines/gateway/configuration.nix):

          ssh-keygen -t ed25519 -N "" -C "wip@$(hostname)" \
            -f ~/.ssh/wip_hub_ed25519
      '';
    };
  };

  # NOTE for future edits: this module is imported by users/kyle/home.nix,
  # which ALL FOUR NixOS hosts import (artemis, atlas, gateway, nixosvm).
  # Enabling belongs in the per-host layers (home/wsl.nix, home/darwin.nix) —
  # never here and never in the shared profile, or gateway would end up
  # snapshotting its own ~/personal and ~/work to itself. Everything except the
  # assertion therefore lives under the mkIf below: atlas, gateway and nixosvm
  # must come out byte-identical to a tree without this module.
  config = lib.mkMerge [
    {
      # Asserted OUTSIDE the mkIf so it is checked on every host, not only
      # where wip is enabled.
      assertions = [
        {
          assertion = !cfg.enable || cfg.host != "";
          message = "kyle.wip.enable is true but kyle.wip.host is unset.";
        }
        # Checked at BUILD time because it cannot be caught at run time: over
        # the limit, ssh exits 255, wip_hub_up reads 255 as "the hub is asleep"
        # (deliberately — see its comment), and the timer goes silent forever.
        # 103 = sun_path (104 on macOS) minus the NUL; ssh binds a temporary
        # "<path>.XXXXXXXXXXXX" first, which is 13 characters longer.
        {
          assertion = !cfg.enable || controlPathLen + 13 <= 103;
          message =
            "kyle.wip: the ssh ControlPath ${controlPath} expands to "
            + "${toString controlPathLen} characters, and ssh's temporary "
            + "'.XXXXXXXXXXXX' variant to ${toString (controlPathLen + 13)} — "
            + "over the 103-character unix-socket limit on macOS. Every hub "
            + "operation would fail with exit 255, indistinguishable from an "
            + "unreachable hub. Shorten xdg.stateHome or the socket name.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      home.packages = [ wip ];

      # Announce a waiting snapshot on ENTERING a repo. The user only remembers
      # `wip` exists while inside a repo, so the hook removes the need to
      # remember at all.
      #
      # COST — measured on ariane 2026-07-28, 200 `cd`s inside an interactive
      # fish, against a scratch repo with a real snapshot and a real diff. The
      # brief claimed "sub-millisecond"; that is wrong by two orders of
      # magnitude. Figures are the delta over fish's own ~19 ms/cd:
      #
      #   outside any repo (gate hits, nothing spawned)   +0.3 ms
      #   inside a repo, nothing waiting                  + 26 ms
      #   inside a repo, snapshot waiting                 + 52 ms
      #   same hook with no gate, outside a repo          + 29 ms
      #
      # The floor is the `wip` process itself: bash startup plus sourcing
      # wip/{wip,main}.sh is ~17 ms before any git runs, and `wip notice`
      # forks git up to five times. Nothing inside `wip` can be trimmed to
      # matter, so the savings have to come from NOT SPAWNING IT — hence the
      # two gates below, both of which use only fish builtins (`test`,
      # `path`, `set`), i.e. zero forks.
      #
      # Re-measured after `wip notice` learnt to classify the snapshot's base
      # commit (wip_base_state in home/wip/wip.sh). That costs ONE more `git`,
      # and only on the announce path: wip_notice classifies after its "is
      # there anything to say?" gate, and wip_snapshot_meta folded the base
      # read into the `git log` the age already needed. 100 runs of the `wip
      # notice` PROCESS against a 120-file fixture — process wall time, not the
      # fish deltas above, so read the columns and not the rows:
      #
      #   outside any repo                7.96 ms -> 8.12 ms
      #   in a repo, nothing waiting     16.41 ms -> 16.64 ms
      #   snapshot waiting               48.87 ms -> 54.52 ms
      #
      # i.e. the `cd` that prints nothing — which is nearly every `cd` — is
      # unchanged, and the one that prints pays a single `git merge-base`.
      #
      # Gate 1, `status is-interactive`: Home Manager sources handler
      # functions from config.fish ABOVE its own `status is-interactive`
      # block (fish.nix `sourceHandlersStr`), so without this the hook fires
      # in scripts too — `fish -c 'cd /tmp'` printed the notice 200 times in
      # testing.
      #
      # Gate 2, the repo-root walk: `wip notice` prints nothing outside a
      # repo, so finding that out without paying for a process is pure win.
      # `test -e` follows symlinks and matches `.git` files (worktrees,
      # submodules) as well as directories, and fish's $PWD is always
      # normalised, so the walk agreed with `git rev-parse --show-toplevel`
      # on every path tried. It can disagree only when GIT_DIR/GIT_WORK_TREE
      # are exported to point somewhere with no `.git` above $PWD; in that
      # case the notice is skipped and bare `wip` still reports.
      #
      # $__wip_last_repo suppresses the re-announce on every subdirectory hop
      # within one repo: the notice is for ENTERING a repo, and reprinting an
      # identical line on each `cd src` / `cd ..` is what trains you to stop
      # reading it. The trade is that a snapshot arriving while you are
      # already sitting in the repo is not announced until you leave and come
      # back — bare `wip` reports it any time.
      programs.fish.functions.__wip_on_pwd = {
        description = "Announce a waiting wip snapshot on entering a repo";
        onVariable = "PWD";
        body = ''
          status is-interactive; or return

          set -l root
          set -l d $PWD
          while true
              if test -e $d/.git
                  set root $d
                  break
              end
              set -l up (path dirname $d)
              # `path dirname /` is `/`, so this is the only loop exit.
              test "$up" = "$d"; and break
              set d $up
          end

          if test -z "$root"
              set -g __wip_last_repo ""
              return
          end
          test "$root" = "$__wip_last_repo"; and return
          set -g __wip_last_repo $root

          # Local ref reads only — no network. Silent unless there is news.
          # stderr is NOT discarded: `wip notice` is quiet on the expected
          # non-events (no shadow cache, no snapshot, no diff), so anything it
          # does write is a real fault and the user is the only one who will
          # ever see it — there is no journal behind an interactive shell.
          ${wip}/bin/wip notice
        '';
      };

      # Linux (artemis): systemd user timer.
      #
      # The mkIf is belt-and-braces — Home Manager declares systemd.user on
      # every platform (systemd.user.enable itself defaults to isLinux) — but it
      # keeps the units from being generated on a hypothetical Darwin host that
      # enabled wip through the shared profile.
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
            # OnStartupSec, NOT OnBootSec. This is the PER-USER manager, which
            # (on WSL especially) starts at first login, long after boot —
            # OnBootSec = 2m would already be in the past by then, so the
            # "settle first" grace period it looks like would not exist.
            # systemd.timer(5) on OnStartupSec: "primarily useful when
            # configured in units running in the per-user service manager, as
            # the user service manager is generally started on first login
            # only, not already during boot."
            OnStartupSec = "2m";
            OnUnitActiveSec = "${toString cfg.interval}m";
            # No Persistent = true: systemd.timer(5) says it "only has an effect
            # on timers configured with OnCalendar=", and this timer is purely
            # monotonic. Nothing is lost by leaving it out — after a suspend the
            # interval has already elapsed, so OnUnitActiveSec fires on resume.
            # (OnCalendar is the wrong trade here anyway: it would only divide
            # the hour evenly for some values of cfg.interval.)
          };
          Install.WantedBy = [ "timers.target" ];
        };
      };

      # macOS (ariane): launchd agent. mkIf on the VALUE, not around the
      # attribute — HM declares launchd.agents on every platform, and its
      # assertion is (launchd.enable && agents != {}) -> isDarwin with
      # launchd.enable defaulting to isDarwin, so this is belt-and-braces too.
      launchd.agents.wip = lib.mkIf pkgs.stdenv.isDarwin {
        enable = true;
        config = {
          ProgramArguments = [ "${tick}" ];
          StartInterval = cfg.interval * 60;
          RunAtLoad = true;
          ProcessType = "Background";
          StandardOutPath = "${stateDir}/agent.log";
          StandardErrorPath = "${stateDir}/agent.log";
        };
      };

      # launchd will not create the parent directory of StandardOutPath, and
      # RunAtLoad fires the first tick the moment HM bootstraps the agent — so
      # this has to land BEFORE setupLaunchAgents, not merely after
      # writeBoundary (both are entryAfter "writeBoundary", i.e. unordered
      # relative to each other). On Linux setupLaunchAgents does not exist and
      # HM's dag ignores an edge to an unknown entry, leaving a plain
      # after-writeBoundary entry.
      home.activation.wipStateDir =
        lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ] ''
          $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg stateDir} ${lib.escapeShellArg cacheDir}
        '';
    })
  ];
}
