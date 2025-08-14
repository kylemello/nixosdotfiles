{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    inputs.catppuccin.homeModules.catppuccin
    ../../home/fish.nix
    ../../home/folders.nix
    ../../home/git.nix
    ../../home/tmux.nix

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

  catppuccin = {
    enable = true;
    flavor = "mocha";
  };

  programs.home-manager.enable = true;
}
