{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Set your time zone.
  time.timeZone = "America/New_York";

  # Set your hostname.
  networking.hostName = "nixosvm";

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
    podman-compose
    dive
    fd
    wget
    fish
    vim
    git
  ];

  # Enable the SSH server.
  services.openssh.enable = true;
  services.k3s = {
    enable = true;
    role = "server";
  };
  networking.firewall.allowedTCPPortRanges = [ 
    # This opens the default kubernetes NodePort Range
    { from = 30000; to = 32767; }
  ];
  networking.firewall.allowedTCPPorts = [ 22 6443 ];
  # Enable Hyper-V guest services for better integration.
  virtualisation.hypervGuest.enable = true;
  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data were taken.
  system.stateVersion = "25.05";
}
