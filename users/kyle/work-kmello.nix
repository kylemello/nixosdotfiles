{ pkgs, lib, ... }:

{
  imports = [
    ../../home/common.nix
    ../../home/fish.nix
  ];

  # Explicitly define the user and home directory for this profile
  home = {
    username = "kmello";
    homeDirectory = "/home/kmello"; # Or "/Users/kmello" on macOS
    stateVersion = "25.05";
  };
}
