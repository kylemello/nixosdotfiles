{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ../../home/fish.nix
    ../../home/folders.nix
    ../../home/git.nix
    ../../home/tmux.nix
    ../../home/catppuccin.nix
    ../../home/claude-code.nix
    # Options only — deliberately NOT enabled here. This profile is imported by
    # all four NixOS hosts (artemis, atlas, gateway, nixosvm); `wip`, the drift
    # alarm and atuin are turned on per-host, in home/wsl.nix (artemis).
    ../../home/wip.nix
    ../../home/drift.nix
    ../../home/atuin.nix

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
