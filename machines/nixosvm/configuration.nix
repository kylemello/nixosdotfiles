{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../hosts/common.nix
    ../../hosts/vm.nix
  ];

  # Machine-specific settings
  networking.hostName = "nixosvm";

  services.openssh.ports = [ 422 ];

  # Assign the Home Manager profile to the user
  home-manager.users.kyle = import ../../users/kyle/home.nix;

  system.stateVersion = "25.05";
}
