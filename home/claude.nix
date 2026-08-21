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
      ];

      # Verified 2026-07-28: Claude Code writes THROUGH these symlinks rather
      # than replacing them, so /config, /plugin and "always allow" all keep
      # working and their changes land in git.
      #
      # settings.json is shared: enabling a plugin on one machine propagates to
      # the other on the next `git pull`. settings.local.json is per-host,
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
      home.file = {
        ".claude/CLAUDE.md".source = link "CLAUDE.md";
        ".claude/skills".source = link "skills";
        ".claude/agents".source = link "agents";
        ".claude/commands".source = link "commands";
        ".claude/settings.json".source = link "settings.json";
        ".claude/settings.local.json".source = link "local/${cfg.host}.json";
      };
    }
  );
}
