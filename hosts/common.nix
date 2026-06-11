{ config, lib, pkgs, ... }:

{
  # If not WSL use the systemd-boot EFI boot loader
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Cachix cache for github:sadjow/claude-code-nix so the always-latest
  # claude-code is fetched as a prebuilt binary instead of built locally.
  nix.settings.extra-substituters = [ "https://claude-code.cachix.org" ];
  nix.settings.extra-trusted-public-keys = [
    "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk="
  ];

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
  programs.nix-ld.libraries = with pkgs; [
    pulseaudio
    alsa-lib
    libpulseaudio
    stdenv.cc.cc.lib
    zlib
    openssl
  ];

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
    extraGroups = [ "wheel" "networkmanager" "docker" "audio" ]; # To use 'sudo'
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

