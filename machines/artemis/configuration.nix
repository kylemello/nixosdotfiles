{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../hosts/common.nix
    ../../hosts/wsl.nix
  ];

  # Machine-specific settings
  networking.hostName = "artemis";

  # Inbound SSH (port 2222 — see hosts/wsl.nix for why not 22).
  users.users.kyle = {
    openssh.authorizedKeys.keys = [
      # 1Password → "Artemis SSH Key" (SHA256:1Of2pktC9/CA+c613eND1O/eueBlrQTSWYUVPxNCYH8),
      # served by the 1Password SSH agent on the Windows host.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvOi1MbxnEQfaFR4D+Ygl69trcLcCz2+bPlWt3jDOQU Artemis SSH Key"
    ];
  };

  # Assign the Home Manager profile to the user
  home-manager.users.kyle = {
    imports = [
      ../../users/kyle/home.nix
      ../../home/wsl.nix
    ];
  };

  boot.supportedFilesystems = [ "nfs" ];

  system.stateVersion = "25.05";
}
