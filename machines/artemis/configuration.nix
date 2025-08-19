{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../hosts/common.nix
    ../../hosts/wsl.nix
  ];

  # Machine-specific settings
  networking.hostName = "artemis";

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
