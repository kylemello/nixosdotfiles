{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../hosts/common.nix
    ../../hosts/wsl.nix
  ];

  # Machine-specific settings
  networking.hostName = "artemis";

  # Assign the Home Manager profile to the user
  home-manager.users.kyle = {
    imports = [
      ../../users/kyle/home.nix
      ../../home/wsl.nix
    ];
  };

  system.stateVersion = "25.05";
}
