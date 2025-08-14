{ pkgs, lib, ... }:

{
  imports = [
    ../../home/fish.nix
    ../../home/folders.nix
    ../../home/git.nix
    ../../home/tmux.nix

    ../../home/packages/base.nix
  ];

  # Explicitly define the user and home directory for this profile
  home = {
    username = "kmello";
    homeDirectory = "/home/kmello"; # Or "/Users/kmello" on macOS
    stateVersion = "25.05";
  };

  catppuccin = {
    enable = true;
    flavor = "mocha";
  };

  programs.home-manager.enable = true;
}
