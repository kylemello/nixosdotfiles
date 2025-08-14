{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../hosts/common.nix
    ../../hosts/wsl.nix
  ];

  # Machine-specific settings
  networking.hostName = "artemis";

  # Define the user for this machine
  users.users.kyle = {
    isNormalUser = true;
    description = "Kyle Mello";
    extraGroups = [ "wheel" ]; # For sudo access
  };

  systemd.user.sockets.podman = {
    enable = true;
    description = "Podman API Socket";
    wantedBy = [ "sockets.target" ];
  };

  # Assign the Home Manager profile to the user
  home-manager.users.kyle = {
    imports = [
      ../../users/kyle/home.nix
      ../../home/wsl.nix
    ];
  };

  system.stateVersion = "25.05";
}
