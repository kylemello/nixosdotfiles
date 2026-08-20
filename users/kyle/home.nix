{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ../../home/fish.nix
    ../../home/folders.nix
    ../../home/git.nix
    ../../home/tmux.nix
    ../../home/catppuccin.nix
    ../../home/claude-code.nix
    ../../home/k9s.nix
    # Options only — deliberately NOT enabled here. This profile is imported by
    # all four NixOS hosts (artemis, atlas, gateway, nixosvm); `wip`, the drift
    # alarm, atuin, the shared ~/.claude, the shared ~/.config/nvim and
    # Syncthing are turned on per-host, in home/wsl.nix (artemis).
    #
    # home/sync.nix especially: gateway already runs the system Syncthing
    # (hosts/sync-hub.nix), and a second user-level one there would share its
    # config directory and rewrite the hub's configuration over the REST API
    # while reporting success. hosts/sync-hub.nix asserts against it.
    ../../home/wip.nix
    ../../home/drift.nix
    ../../home/atuin.nix
    ../../home/claude.nix
    ../../home/nvim.nix
    ../../home/sync.nix
    ../../home/opencode.nix
    ../../home/docker-composes.nix

    ../../home/packages/base.nix
    ../../home/packages/dev.nix
    ../../home/packages/misc.nix
  ];

  home = {
    username = "kyle";
    homeDirectory = "/home/kyle";
    stateVersion = "25.05";
  };

  programs.home-manager.enable = true;
}
