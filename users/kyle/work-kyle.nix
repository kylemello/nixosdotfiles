{ pkgs, lib, ... }:

{
  imports = [
    ../../home/common.nix
    ../../home/fish.nix
  ];

  # Explicitly define the user and home directory for this profile
  home = {
    username = "kyle";
    homeDirectory = "/home/kyle"; # Or "/Users/kyle" on macOS
    stateVersion = "25.05";
  };
}
