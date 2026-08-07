{ config, lib, pkgs, ... }:

# An always-on Claude Code Remote Control SERVER (`claude remote-control`), so a
# headless box can host the sessions you drive from claude.ai/code or the Claude
# mobile app. Enabled from a per-host user module, never from
# users/kyle/home.nix — see home/gateway.nix.
#
# Server mode, NOT `claude --remote-control`. The flag starts one interactive
# session that happens to be reachable remotely; the SUBCOMMAND is a persistent
# server that accepts many concurrent sessions (32 by default) and creates new
# ones on demand when you ask for one from the phone or the web. That is the
# whole point here: one unit, but a fresh conversation whenever you want it.
#
# `claude remote-control` is hidden from `claude --help`'s command list because
# Claude Code gates it behind an eligibility check, so don't go looking for it
# there. `claude remote-control --help` prints the real flag list — but only for
# an eligible account, and it errors otherwise.
#
# Auth is NOT declarative and NOT a token: Remote Control explicitly rejects the
# long-lived tokens from `claude setup-token` / CLAUDE_CODE_OAUTH_TOKEN
# ("Remote Control requires a full-scope login token"). Run `claude auth login`
# ONCE per host, interactively.
let
  cfg = config.kyle.claudeRemote;

  # Built in Nix rather than interpolated into the script so the optional flags
  # are genuinely absent — passing `--capacity ""` is not the same as omitting
  # it, and Claude Code's own default (32) is the right fallback.
  args = lib.escapeShellArgs (
    [ "remote-control" "--spawn" cfg.spawn "--permission-mode" cfg.permissionMode ]
    ++ lib.optionals (cfg.name != "") [ "--name" cfg.name ]
    ++ lib.optionals (cfg.capacity != null) [ "--capacity" (toString cfg.capacity) ]
  );

  # home.sessionPath entries are shell FRAGMENTS — they can contain $HOME — so
  # they cannot be dropped into a systemd `Environment=PATH`: systemd does no
  # shell expansion there and would put a directory literally named `$HOME` on
  # PATH. Expand them in a wrapper instead, exactly as home/wip.nix does for its
  # timer. Trailing ":" per entry rather than a ":"-join, so an EMPTY
  # sessionPath contributes nothing at all — a leading ":" is an empty PATH
  # entry, which POSIX shells read as "." (the cwd, on the PATH of a service).
  sessionPathPrefix = lib.concatMapStrings (p: "${p}:") config.home.sessionPath;

  # writeShellScriptBin, not writeShellApplication: the latter pulls shellcheck,
  # a heavy and often-uncached Haskell build. See CLAUDE.md.
  server = pkgs.writeShellScriptBin "claude-remote-server" ''
    set -euo pipefail
    # A systemd user unit never sources hm-session-vars.sh, so without this the
    # server — and every tool Claude shells out to — starts with a nearly empty
    # PATH: no git, no docker, no nix. /etc/profiles/per-user/$USER/bin is where
    # Home Manager packages land under useUserPackages (set in flake.nix).
    export PATH="${sessionPathPrefix}/etc/profiles/per-user/$USER/bin:/run/wrappers/bin:/run/current-system/sw/bin''${PATH:+:$PATH}"
    exec ${pkgs.claude-code}/bin/claude ${args}
  '';
in
{
  options.kyle.claudeRemote = {
    enable = lib.mkEnableOption ''
      an always-on `claude remote-control` server as a systemd user service.

      Off by default and enabled per-host, because it presumes a box that is
      always up and that nobody sits in front of. It also presumes
      `kyle.claude.enable` on the same host: server mode rooted at $HOME needs
      the hasTrustDialogAccepted flag that home/claude-code.nix writes, since
      Claude Code's startup trust dialog never persists trust for a home
      directory
    '';

    name = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Title for the session pre-created at startup, as shown in the session
        list at claude.ai/code. Empty means pass no --name, and Claude Code
        auto-generates one like "gateway-graceful-unicorn" (the prefix defaults
        to the hostname).

        Worth setting, because the ENVIRONMENT id is not stable: a fresh
        `env_...` is minted on every start, so the
        `claude.ai/code?environment=...` URL cannot be bookmarked and the
        session list is how you find the box. The trade-off is that each
        restart pre-creates another session with this same title, so repeated
        restarts leave identical-looking dead entries behind. If that becomes
        annoying, the alternative is --no-create-session-in-dir (not modelled
        here — it is unverified whether an environment with zero sessions is
        still visible in the Code list, and if it isn't there is no way in).
      '';
      example = "gateway";
    };

    spawn = lib.mkOption {
      type = lib.types.enum [ "same-dir" "worktree" "session" ];
      default = "same-dir";
      description = ''
        How the server creates on-demand sessions. "same-dir": all sessions
        share workingDirectory, so they can collide when editing the same
        files. "worktree": each on-demand session gets its own git worktree —
        REQUIRES workingDirectory to be a git repository. "session": classic
        single-session mode, which defeats the purpose of running a server.

        Note that "worktree" here would mint a worktree per session with
        nothing to garbage-collect them, which is why the always-on unit stays
        on "same-dir" and worktrees are left as a per-task thing you ask for.
      '';
    };

    capacity = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        Maximum concurrent sessions. null omits the flag and takes Claude
        Code's own default of 32. Cannot be combined with spawn = "session".
      '';
      example = 4;
    };

    permissionMode = lib.mkOption {
      type = lib.types.enum [
        "acceptEdits" "auto" "bypassPermissions" "default" "dontAsk" "plan"
      ];
      default = "auto";
      description = ''
        Permission mode applied to SPAWNED sessions. "auto" runs the classifier
        (17 allow rules, 65 soft-deny, 1 hard-deny); soft-denied calls become
        prompts, which Remote Control forwards to your phone and holds open
        until answered — so this does not need to be bypassPermissions to be
        usable unattended.

        One interaction to watch when workingDirectory is $HOME rather than a
        repo: auto mode's "Local Operations" allow rule scopes itself to "the
        repository the session started in", and calls wandering into ~/ scope
        escalation. Rooted at $HOME there is no repository, so ordinary edits
        may fall outside that rule and prompt more than expected. The lever is
        the autoMode.environment block in settings; the fallbacks are
        "acceptEdits", or re-rooting at a repo.
      '';
    };

    workingDirectory = lib.mkOption {
      type = lib.types.str;
      default = config.home.homeDirectory;
      description = ''
        Directory the server is rooted at. Server mode has NO --add-dir, so
        this single path decides everything the sessions can reach — which is
        why the default is the whole home directory rather than a project.
      '';
      example = "/home/kyle/nixosdotfiles";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(cfg.spawn == "session" && cfg.capacity != null);
        message = "kyle.claudeRemote: --capacity cannot be combined with "
          + "--spawn=session; leave capacity null or pick another spawn mode.";
      }
    ];

    # `claude remote-control` asks "Enable Remote Control? (y/n)" the first time
    # it runs on a machine and records the answer as remoteDialogSeen in
    # ~/.claude.json. A systemd unit has no TTY and stdin at EOF, so it can
    # never answer: the process exits, Restart=always brings it straight back,
    # and the service hard-loops. Observed on gateway 2026-08-07 — the unit sat
    # in "activating" with a climbing restart counter and the prompt as the last
    # line of every journal entry.
    #
    # Declared rather than left to the one-time `printf 'y\n' | claude
    # remote-control` that clears it by hand, because the failure comes straight
    # back the moment ~/.claude.json is reset or this module reaches a new host.
    #
    # Kept out of home/claude-code.nix's merge on purpose: that module is
    # imported by every host, and this key should only be asserted where a
    # headless server actually needs it. Activation is one sequential script, so
    # two read-modify-write merges of the same file cannot race — whichever runs
    # second reads the first's output. The -e guard covers the ordering case
    # where claudeCodeJson has not created the file yet; the key then lands on
    # the next activation, and the service is idle until it does.
    home.activation.claudeRemoteDialogSeen =
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        claudeJson="$HOME/.claude.json"
        jq=${pkgs.jq}/bin/jq
        if [ -e "$claudeJson" ] && "$jq" -e . "$claudeJson" >/dev/null 2>&1; then
          tmp="$(mktemp "$claudeJson.XXXXXX")"
          if "$jq" '.remoteDialogSeen = true' "$claudeJson" > "$tmp"; then
            $DRY_RUN_CMD mv "$tmp" "$claudeJson"
          else
            rm -f "$tmp"
            echo "claude-remote: failed to set remoteDialogSeen in $claudeJson" >&2
          fi
        fi
      '';

    systemd.user.services.claude-remote = {
      Unit = {
        Description = "Claude Code Remote Control server";
        Documentation = [ "https://code.claude.com/docs/en/remote-control" ];

        # Ordering only, no Wants=: both units are pulled in by default.target
        # anyway, and if the keyring is somehow absent we would still rather
        # start and let Restart= sort it out than refuse to run. Credentials can
        # live in the Secret Service, which hosts/common.nix unlocks with an
        # empty password at boot on headless hosts.
        After = [ "gnome-keyring-secrets.service" ];

        # Restart=always below is the RECONNECT mechanism, not merely crash
        # recovery: Remote Control exits on its own after roughly ten minutes
        # without network. At the default StartLimitBurst=5 per 10s a long
        # outage would exhaust the budget and leave the unit dead permanently,
        # which is precisely the failure this service exists to avoid. Note
        # this key belongs to [Unit], not [Service] — systemd moved it, and
        # putting it under Service is silently ignored with a warning.
        StartLimitIntervalSec = 0;
      };

      Install.WantedBy = [ "default.target" ];

      Service = {
        # "simple", and deliberately no tmux. Wrapping this in `tmux
        # new-session -d` would make systemd supervise the tmux SERVER instead
        # of claude, so Restart=always would stop firing the moment claude died
        # while tmux lived — and `tmux new-session` would join the user's
        # existing default-socket server, outside this unit's cgroup entirely.
        # Verified 2026-08-07: `claude remote-control` runs fine with no TTY.
        # All that is lost are the runtime keypresses (space for a QR code, `w`
        # to toggle spawn mode), neither of which means anything on a box
        # nobody sits at. Live status is `journalctl --user -u claude-remote`.
        Type = "simple";
        WorkingDirectory = cfg.workingDirectory;
        ExecStart = "${server}/bin/claude-remote-server";
        Restart = "always";
        RestartSec = 10;
      };
    };
  };
}
