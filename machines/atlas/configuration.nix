{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../hosts/common.nix
  ];

  # Machine-specific settings
  networking.hostName = "atlas";

  nixpkgs.config.allowUnfree = true;

  services.qemuGuest.enable = true;

  # Define the user for this machine
  users.users.kyle = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ1EH7kBFr7SWpBlQ+R80bMFDUVSU0LvBoNDYhgj4RWr"
    ];
  };

  # Assign the Home Manager profile to the user
  home-manager.users.kyle = import ../../users/kyle/home.nix;

  system.stateVersion = "25.05";
}
