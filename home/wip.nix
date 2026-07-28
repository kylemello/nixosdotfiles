{ config, lib, pkgs, ... }:

let
  cfg = config.kyle.wip;

  # The script is assembled rather than templated so home/wip/*.sh stay
  # directly testable (see tests/wip.test.sh).
  wip = pkgs.writeShellScriptBin "wip" ''
    set -euo pipefail
    # config.home.sessionPath is appended because this script runs in contexts
    # that never source hm-session-vars.sh — above all the systemd user timer,
    # whose unit has no Environment=PATH. On artemis `ssh.exe` is a bare command
    # name living under /mnt/c/…/OpenSSH/, and hosts/wsl.nix sets
    # wsl.interop.includePath = false, so home.sessionPath is its ONLY source.
    # Without this the timer resolves nothing, wip_hub_up reads the shell's 127
    # as "hub away", and the timer pushes nothing and logs nothing every 5
    # minutes — while `wip push` typed by hand still works, because an
    # interactive shell does have the directory.
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
    export WIP_CACHE=${lib.escapeShellArg "${config.xdg.cacheHome}/wip"}
    export WIP_STATE=${lib.escapeShellArg "${config.xdg.stateHome}/wip"}

    # Bound git's SSH too, not just wip_hub_up's probe — the hub is LAN-only,
    # so a push attempt from off-network must fail fast rather than block.
    #
    # The BINARY is per-host and must not be hardcoded to pkgs.openssh. On artemis
    # the 1Password SSH agent lives on the Windows host, which is why
    # home/wsl.nix sets programs.git.settings.core.sshCommand = "ssh.exe".
    # GIT_SSH_COMMAND OVERRIDES core.sshCommand, so hardcoding Nix's openssh here
    # would bypass that agent entirely: every push from artemis would fail auth,
    # and with BatchMode=yes it would fail silently, in the timer's journal only.
    # wip_hub_up's bare `ssh` has the same problem via the PATH above.
    export WIP_SSH=${lib.escapeShellArg cfg.sshCommand}
    export GIT_SSH_COMMAND="$WIP_SSH -o BatchMode=yes -o ConnectTimeout=5"

    source ${./wip/wip.sh}
    source ${./wip/main.sh}
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

    sshCommand = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.openssh}/bin/ssh";
      description = ''
        The ssh binary `wip` uses, for both `git push` and `wip_hub_up`.
        MUST be overridden to "ssh.exe" on artemis (in home/wsl.nix): its
        1Password agent lives on the Windows host, and Nix's openssh cannot
        reach it. Getting this wrong makes every push fail authentication
        silently, visible only in the timer's journal.

        Three constraints on the value:

        1. OpenSSH-CLI-compatible: `wip_hub_up` appends `-o BatchMode=yes
           -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new` after it,
           and GIT_SSH_COMMAND appends `-o BatchMode=yes -o ConnectTimeout=5`.
           `ssh.exe` (Windows OpenSSH) accepts all of these.
        2. A bare binary, NO arguments. git shell-parses GIT_SSH_COMMAND, but
           wip.sh invokes "''${WIP_SSH:-ssh}" as a single quoted word — so a
           value with flags in it would work in git and break every direct ssh
           call site.
        3. Resolvable from a NON-INTERACTIVE PATH. The timer is a systemd user
           unit with no Environment=PATH, so it never sees hm-session-vars.sh.
           A bare name like `ssh.exe` only works because the wrapper appends
           config.home.sessionPath to its own PATH; an absolute path is always
           safe.
      '';
      example = "ssh.exe";
    };
  };

  config = {
    # Asserted OUTSIDE the mkIf below so it is checked on every host, not only
    # where wip is enabled.
    assertions = [
      {
        assertion = !cfg.enable || cfg.host != "";
        message = "kyle.wip.enable is true but kyle.wip.host is unset.";
      }
    ];

    # NOTE for future edits: this module is imported by users/kyle/home.nix,
    # which ALL FOUR NixOS hosts import (artemis, atlas, gateway, nixosvm).
    # Enabling belongs in the per-host layers (home/wsl.nix, home/darwin.nix) —
    # never here and never in the shared profile, or gateway would end up
    # snapshotting its own ~/personal and ~/work to itself.
    home.packages = lib.mkIf cfg.enable [ wip ];
  };
}
