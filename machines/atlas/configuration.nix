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

  boot.initrd.kernelModules = [ "nvidia" "nvidia-modeset" "nvidia_uvm" "nvidia_drm" ];

  hardware.nvidia-container-toolkit.enable = true;
  services.xserver.videoDrivers = ["nvidia"];
  hardware.nvidia = {
    modesetting.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
    open = false;
  };

  fileSystems = {
    "/mnt/vda" = {
      device = "/dev/disk/by-uuid/8ad3504b-8043-437d-a993-c46d9896462d";
      fsType = "ext4";
    };

    "/mnt/vdb" = {
      device = "/dev/disk/by-uuid/936d4399-1e5a-4d52-b920-661cc6e420ff";
      fsType = "ext4";
    };

    "/mnt/vdc" = {
      device = "/dev/disk/by-uuid/3b7e3808-377e-4cab-a707-c8da144e6e2e";
      fsType = "ext4";
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  # Assign the Home Manager profile to the user
  home-manager.users.kyle = import ../../users/kyle/home.nix;

  system.stateVersion = "25.05";
}
