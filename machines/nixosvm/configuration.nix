{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../hosts/common.nix
    ../../hosts/desktop.nix
    ../../hosts/vm.nix
  ];

  nixpkgs.config.allowUnfree = true;

  # Assign the Home Manager profile(s) to the user
  home-manager.users.kyle = {
    imports = [
      ../../users/kyle/home.nix
      ../../home/profiles/desktop.nix
    ];
  };

  # Needed for 4K resolution (Tested with Wayland Gnome)
  # Get the "Virtual-1" name from doing 'ls /sys/class/drm'
  # Don't forget to configure from the windows side as well with
  # 'Set-VMVideo -VMName "<vm_name>" -HorizontalResolution 3840 -VerticalResolution 2160 -ResolutionType Single'
  boot.kernelParams = [ "video=Virtual-1:3840x2160@60" ]; 

  # Machine-specific settings
  networking.hostName = "nixosvm";

  services.openssh.ports = [ 422 ];

  system.stateVersion = "25.05";
}
