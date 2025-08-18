{ config, lib, pkgs, ... }:

{
  # If not WSL use the systemd-boot EFI boot loader
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  boot.loader.systemd-boot.enable = lib.mkIf (!config.wsl.enable) true;
  boot.loader.efi.canTouchEfiVariables = lib.mkIf (!config.wsl.enable) true;

  # Set your time zone.
  time.timeZone = "America/New_York";

  # Enable networking with DHCP.
  networking.networkmanager.enable = true;

  programs.fish.enable = true;
  users.defaultUserShell = pkgs.fish;

  # Define a user account.
  users.users.kyle = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # To use 'sudo'
  };

  # List packages you want to install.
  environment.systemPackages = with pkgs; [
    home-manager
    fd
    wget
    fish
    vim
    git
  ];

  # Enable the SSH server.
  services.openssh.enable = lib.mkDefault true;

  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };
}

