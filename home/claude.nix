{ config, lib, pkgs, ... }:

# Claude Code's *editable* config (~/.claude), shared between artemis and ariane
# through this repo. The MCP server list is a separate concern and lives in
# home/claude-code.nix — see the "Deliberately NOT managed" list below.
#
# The contents were produced by a union of both machines' files, not a copy from
# one: artemis contributed model/spinnerVerbs/plugins, ariane contributed
# CLAUDE.md and the deploying-laravel-cloud skill. See task-11 for the audit.
let
  cfg = config.kyle.claude;
in
{
  options.kyle.claude = {
    enable = lib.mkEnableOption ''
      the shared ~/.claude configuration (CLAUDE.md, skills, agents, commands,
      settings.json, settings.local.json) symlinked out of this repo.

      Off by default and enabled per-host in home/wsl.nix and home/darwin.nix,
      NOT in users/kyle/home.nix — that profile is imported by all four NixOS
      hosts, and atlas/gateway/nixosvm must stay byte-identical to a tree
      without this module. They also have no ~/nixosdotfiles checkout to point
      the symlinks at, so enabling it there would produce dangling links
    '';

    host = lib.mkOption {
      type = lib.types.str;
      # MUST have a default even though the config block is gated on `enable`:
      # users/kyle/home.nix reaches all four NixOS hosts, and an option with no
      # default is a hard eval error the moment anything touches it.
      default = "";
      description = ''
        Which claude/local/<host>.json this machine uses for the settings that
        genuinely cannot be shared (extraKnownMarketplaces holds absolute,
        platform-specific paths). Set alongside kyle.wip.host in home/wsl.nix
        and home/darwin.nix.
      '';
      example = "artemis";
    };

    settings = lib.mkOption {
      type = lib.types.str;
      default = "settings.json";
      description = ''
        Which file in claude/ ~/.claude/settings.json links to: settings.json is
        the personal account's, settings.work.json the work account's (which
        ~/.claude-work always gets).
      '';
      example = "settings.work.json";
    };

    workAccount = {
      enable = lib.mkEnableOption ''
        a second Claude Code login, picked by the folder `claude` starts in.
        Under one of `dirs` it runs with CLAUDE_CONFIG_DIR=~/.claude-work (the
        work account); anywhere else it gets the default ~/.claude (personal).
        Each dir holds its own login, .claude.json and settings.json; CLAUDE.md,
        skills, agents, commands and the plugins dir are shared. Needs
        kyle.claude.enable
      '';

      dirs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "${config.home.homeDirectory}/work" ];
        defaultText = lib.literalExpression ''[ "''${config.home.homeDirectory}/work" ]'';
        description = ''
          Absolute folders whose subtree uses the work account. Matched against
          both the logical and the physical cwd, so a symlink inside one of
          these (~/work/work-knowledge-repo -> /mnt/c/...) counts when entered
          through it, but its target reached directly does not.
        '';
      };
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      internal = true;
      description = ''
        The `claude` for callers that pin a store path instead of using PATH
        (home/q.nix): the account-switching wrapper when workAccount is on.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    let
      # Point at the live working copy, NOT the nix store, so edits take effect
      # immediately and land in git. mkOutOfStoreSymlink is what makes the
      # target writable — a plain home.file source would be a read-only store
      # path, and Claude Code needs to write settings.json for /config,
      # /plugin and "always allow" to work.
      #
      # That writability has a limit, found 2026-08-20: the link is a DOUBLE hop
      # (~/.claude/x -> /nix/store/...-home-manager-files/x -> this repo), so
      # anything that writes via write-then-rename creates its temp file next to
      # the STORE entry and dies with EROFS. The TUI writes in place and is fine;
      # the `claude plugin` CLI does not, so `claude plugin install` and
      # `claude plugin marketplace add` both fail here. Use /plugin in the TUI,
      # or edit claude/settings.json and claude/local/<host>.json by hand.
      #
      # Directory-source marketplaces in claude/local/<host>.json need their repo
      # CLONED on each machine — nothing here clones them, and a missing path is
      # a silently absent marketplace rather than an error. Each one's `path` is
      # the clone it expects; `git pull` in that clone is how it updates. A
      # marketplace whose plugins are disabled in settings.json still needs its
      # clone present, since the path is resolved either way.
      repo = "${config.home.homeDirectory}/nixosdotfiles/claude";
      link = p: config.lib.file.mkOutOfStoreSymlink "${repo}/${p}";

      work = cfg.workAccount;
      homeDir = config.home.homeDirectory;

      # On PATH ahead of pkgs.claude-code (hiPrio), so fish, bash scripts, tmux
      # and editors that run `claude` all go through it. Decides per launch:
      # CLAUDE_CONFIG_DIR moves the login (.credentials.json) and .claude.json
      # into ~/.claude-work (read out of the 2.1.308 bundle, then strace on 2.1.309
      # showed a ~/work launch opening ~/.claude-work/.credentials.json, 2026-10-23).
      # CLAUDE_CODE_PLUGIN_CACHE_DIR keeps work on ~/.claude/plugins, since the
      # installed_plugins.json there holds absolute ~/.claude/plugins paths;
      # org-synced plugins sit in per-<org>_<user> buckets, so the two
      # accounts don't trample each other.
      #
      # A CLAUDE_CONFIG_DIR inherited from a work session is decided again, so
      # `claude` run from a work session in a personal folder switches back.
      # Any other value was set by hand and is left alone.
      wrapper = pkgs.writeShellScriptBin "claude" ''
        set -euo pipefail

        work=${lib.escapeShellArg "${homeDir}/.claude-work"}
        plugins=${lib.escapeShellArg "${homeDir}/.claude/plugins"}

        under() { case "$1/" in "$2"/*) return 0 ;; esac; return 1; }

        if [ -z "''${CLAUDE_CONFIG_DIR:-}" ] || [ "$CLAUDE_CONFIG_DIR" = "$work" ]; then
          unset CLAUDE_CONFIG_DIR
          if [ "''${CLAUDE_CODE_PLUGIN_CACHE_DIR:-}" = "$plugins" ]; then
            unset CLAUDE_CODE_PLUGIN_CACHE_DIR
          fi
          # bash resets an inherited PWD that doesn't match the real cwd, so
          # $PWD is trustworthy here even when an editor spawned us.
          for root in ${lib.escapeShellArgs (map (lib.removeSuffix "/") work.dirs)}; do
            if under "$PWD" "$root" || under "$(pwd -P)" "$root"; then
              export CLAUDE_CONFIG_DIR="$work" CLAUDE_CODE_PLUGIN_CACHE_DIR="$plugins"
              break
            fi
          done
        fi

        exec ${pkgs.claude-code}/bin/claude "$@"
      '';

      # The same links in each config dir, so both accounts see one CLAUDE.md
      # and skill set. settings.json is per account: the personal org syncs
      # every Anthropic knowledge-work plugin from claude.ai (37 MCP servers
      # wanting a sign-in), so its file turns syncClaudeAiPlugins off and leaves
      # out the work plugins, while the work org's few synced ones stay on.
      shared = dir: settings: {
        "${dir}/CLAUDE.md".source = link "CLAUDE.md";
        "${dir}/skills".source = link "skills";
        "${dir}/agents".source = link "agents";
        "${dir}/commands".source = link "commands";
        "${dir}/settings.json".source = link settings;
        "${dir}/settings.local.json".source = link "local/${cfg.host}.json";
      };
    in
    {
      # A missing/typo'd host would silently produce a dangling
      # ~/.claude/settings.local.json -> .../claude/local/.json, which Claude
      # Code treats as "no local settings" without complaining. Fail the build
      # instead. The file must also actually exist in the repo — flakes only
      # see git-tracked files, so a forgotten `git add` shows up here too.
      assertions = [
        {
          assertion = cfg.host != "";
          message = "kyle.claude.enable is on but kyle.claude.host is empty; "
            + "set it to the basename of a file in claude/local/ (artemis, ariane).";
        }
        {
          assertion = builtins.pathExists (../claude/local + "/${cfg.host}.json");
          message = "kyle.claude.host = \"${cfg.host}\" but claude/local/${cfg.host}.json "
            + "does not exist in the flake (did you forget to `git add` it?).";
        }
        {
          assertion = builtins.pathExists (../claude + "/${cfg.settings}");
          message = "kyle.claude.settings = \"${cfg.settings}\" but claude/${cfg.settings} "
            + "does not exist in the flake.";
        }
      ];

      # Verified 2026-07-28: Claude Code writes THROUGH these symlinks rather
      # than replacing them, so /config, /plugin and "always allow" all keep
      # working and their changes land in git.
      #
      # settings.json (personal) and settings.work.json are each shared across
      # machines: enabling a plugin on one propagates to the other on the next
      # `git pull`, but only for that account. settings.local.json is per-host,
      # holding only what genuinely cannot be shared — the absolute marketplace
      # paths. Notably the podman permissions that used to sit in ariane's
      # settings.local.json were moved into the SHARED settings.json: it is
      # unverified whether settings.local.json deep-merges or replaces
      # permissions.allow, and keeping a single allowlist makes the answer
      # irrelevant.
      #
      # Deliberately NOT managed:
      #   projects/          session transcripts, machine-specific paths, large
      #   history.jsonl      append-only from two machines, would conflict
      #   .credentials.json  secret
      #   .claude.json       per-project state and MCP servers; uses
      #                      write-then-rename, so symlinking it is unsafe. It
      #                      is instead deep-merged into by home/claude-code.nix
      #   cache/ daemon/ session-env/ shell-snapshots/ telemetry/ file-history/
      #   backups/ plugins/  all derived or machine-local
      #
      # ~/.claude-work gets the same links, with settings.work.json as its
      # settings.json, and nothing else. Its .claude.json,
      # .credentials.json, history.jsonl and projects/ are its own: projects/
      # holds the transcripts and auto-memory, keyed by path, so the work
      # repos' entries were moved over by hand when this was set up.
      home.file = shared ".claude" cfg.settings
        // lib.optionalAttrs work.enable (shared ".claude-work" "settings.work.json");

      home.packages = lib.mkIf work.enable [ (lib.hiPrio wrapper) ];
      kyle.claude.package = lib.mkIf work.enable wrapper;
    }
  );
}
