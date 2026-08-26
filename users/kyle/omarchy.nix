{ config, pkgs, lib, inputs, ... }:

# Standalone Home Manager profile for `omarchy` — an Arch/Omarchy Hyprland
# desktop. Hand-picked rather than copied from users/kyle/ariane.nix: Omarchy
# already provides the desktop, the theming and its own neovim, so this profile
# takes the toolchain and the shared dotfiles and leaves the rest alone. See
# home/omarchy.nix for what is deliberately left out and why.
{
  imports = [
    # Shared with every other machine.
    ../../home/fish.nix
    ../../home/folders.nix
    ../../home/git.nix
    ../../home/tmux.nix
    ../../home/claude-code.nix

    # catppuccin is imported for home/k9s.nix's sake only; home/omarchy.nix
    # forces autoEnable off and re-enables the single k9s port, because Omarchy
    # generates the rest of ~/.config from its own theme.
    ../../home/catppuccin.nix
    ../../home/k9s.nix

    ../../home/packages/base.nix
    ../../home/packages/dev.nix
    ../../home/packages/misc.nix

    # Options only; home/omarchy.nix does the enabling.
    #
    # home/wip.nix and home/sync.nix are deliberately NOT imported: this machine
    # does not participate in the wip hub or the Syncthing pair, so carrying
    # their options would only advertise switches nothing here can turn on.
    # Nothing else depends on them — home/drift.nix reads the last-switch stamp
    # by path, not through kyle.wip.
    ../../home/drift.nix
    ../../home/atuin.nix
    ../../home/claude.nix
    ../../home/nvim.nix

    ../../home/omarchy.nix
  ];

  home = {
    username = "kyle";
    homeDirectory = "/home/kyle";
    stateVersion = "25.05";
  };

  programs.home-manager.enable = true;
}
