{ lib, pkgs, ... }:

{
  # The host aliases and 1Password agent wiring, shared with home/omarchy.nix.
  imports = [ ../ssh.nix ];

  home.packages = with pkgs; [
    ghostty
  ];

  programs.git = {
    extraConfig = {
      "gpg \"ssh\"" = {
        program = "${lib.getExe' pkgs._1password-gui "op-ssh-sign"}";
      };
    };
  };
}
