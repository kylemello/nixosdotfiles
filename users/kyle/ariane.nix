{ config, pkgs, lib, inputs, ... }:

# Standalone Home Manager profile for `ariane` — a macOS (aarch64-darwin) work
# laptop. Modeled on artemis's user environment (users/kyle/home.nix), but
# swaps the WSL layer (home/wsl.nix) for the macOS layer (home/darwin.nix).
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

    # Options only; home/darwin.nix does the enabling. See home/wip.nix.
    ../../home/wip.nix
    ../../home/drift.nix
    ../../home/atuin.nix

    ../../home/darwin.nix
  ];

  home = {
    username = "kyle";
    homeDirectory = "/Users/kyle";
    stateVersion = "25.05";
  };

  programs.home-manager.enable = true;
}
