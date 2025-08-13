{ config, pkgs, ... }:

{
  imports = [
    # Import the reusable building blocks
    ../../hosts/common.nix
  ];

  # Machine-specific settings
  networking.hostName = "atlas";

  # Define the user for this machine
  users.users.kyle = {
    isNormalUser = true;
    description = "Kyle Mello";
    extraGroups = [ "wheel" ]; # For sudo access
  };

  # Assign the Home Manager profile to the user
  home-manager.users.kyle = import ../../users/kyle/home.nix;

  system.stateVersion = "25.05";
}
