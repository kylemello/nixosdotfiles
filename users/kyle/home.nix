{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ../../home/fish.nix
    ../../home/folders.nix
    ../../home/git.nix
    ../../home/tmux.nix
    ../../home/catppuccin.nix

    ../../home/packages/base.nix
    ../../home/packages/dev.nix
    ../../home/packages/misc.nix
  ];

  home = {
    username = "kyle";
    homeDirectory = "/home/kyle";
    stateVersion = "25.05";

    sessionVariables = {
      DOCKER_HOST = "unix:///run/user/1000/podman/podman.sock";
    };
  };

  programs.home-manager.enable = true;
}
