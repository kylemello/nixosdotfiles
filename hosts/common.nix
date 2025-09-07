{ config, lib, pkgs, ... }:

{
  # If not WSL use the systemd-boot EFI boot loader
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  boot.loader.systemd-boot.enable = lib.mkIf (!config.wsl.enable) true;
  boot.loader.efi.canTouchEfiVariables = lib.mkIf (!config.wsl.enable) true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  nix.settings.trusted-users = [ "root" "kyle" ]; # Needed for devenv

  nix.gc = {
    automatic = true;
    dates = "Wed *-*-* 03:00:00";
    options = "--delete-older-than 7d";
  };

  programs.nix-ld.enable = true;

  # Set your time zone.
  time.timeZone = "America/New_York";

  # Enable networking with DHCP.
  networking.networkmanager.enable = true;

  programs.fish.enable = true;
  users.defaultUserShell = pkgs.fish;

  # Define a user account.
  users.users.kyle = {
    isNormalUser = true;
    description = "Kyle Mello";
    extraGroups = [ "wheel" "networkmanager" "docker" ]; # To use 'sudo'
  };

  # List packages you want to install.
  environment.systemPackages = with pkgs; [
    home-manager
    pciutils
    fd
    wget
    fish
    lsof
    vim
    git
  ];

  # Enable the SSH server.
  services.openssh.enable = lib.mkDefault true;

  virtualisation.containers.enable = true;
  virtualisation.docker = {
    enable = true;
  };
}

