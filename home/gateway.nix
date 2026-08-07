{ ... }:

# Per-host user layer for gateway, the always-on homelab box. Sits alongside
# home/wsl.nix (artemis) and home/darwin.nix (ariane), and follows the same
# split: users/kyle/home.nix carries the OPTIONS for all four NixOS hosts, this
# file does the ENABLING for this one, and machines/gateway/configuration.nix
# imports both.
#
# Deliberately does NOT enable:
#   kyle.sync  — gateway runs the SYSTEM Syncthing (hosts/sync-hub.nix), which
#                asserts against a Home Manager instance sharing its configDir.
#   kyle.wip   — gateway IS the wip hub; the clients are artemis and ariane.
{
  imports = [ ./claude-remote.nix ];

  # The shared ~/.claude — CLAUDE.md, skills, agents, commands, settings.json —
  # symlinked out of this repo, the same set artemis and ariane get. Two reasons
  # it is on here rather than left off like atlas/nixosvm:
  #
  #   1. The Remote Control sessions below are for real work, so they want the
  #      same skills and settings as the machines you drive by hand.
  #   2. It is what writes projects[$HOME].hasTrustDialogAccepted (the homeTrust
  #      block in home/claude-code.nix, gated on exactly this option). Server
  #      mode is rooted at $HOME here, and Claude Code's startup trust dialog
  #      never persists trust for a home directory — so without this the server
  #      would re-ask on every restart, with nobody sitting there to answer.
  #
  # Read the trade-off in home/claude-code.nix before assuming this is free: a
  # trusted $HOME transitively trusts every repo beneath it, so any .claude/
  # settings, hooks and .mcp.json under ~ apply without a prompt. On a box whose
  # whole job is to run unattended sessions rooted at ~, that is the point.
  #
  # REQUIRES ~/nixosdotfiles to be cloned on this box — the ~/.claude symlinks
  # point into the live working copy (mkOutOfStoreSymlink) and dangle silently
  # otherwise. It also brings the five workstationServers MCPs, each of which
  # still needs its own one-time interactive auth here.
  kyle.claude = {
    enable = true;
    host = "gateway";
  };

  # The always-on `claude remote-control` server. See home/claude-remote.nix.
  kyle.claudeRemote = {
    enable = true;

    # Rooted at $HOME (the module default) rather than a project directory:
    # server mode has no --add-dir, so the single root has to cover everything
    # the sessions need to reach — ~/nixosdotfiles, ~/work, and the box itself
    # for homelab ops. The price is that spawn = "worktree" is unavailable,
    # since $HOME is not a git repository.
    #
    # capacity is left null (Claude Code's own default, 32) and permissionMode
    # at "auto", which matches the defaultMode already set in the shared
    # claude/settings.json.
    name = "gateway";
  };
}
