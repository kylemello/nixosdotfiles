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
    gnome-keyring # gnome-keyring-daemon on PATH
  ];

  # Enable the SSH server.
  services.openssh.enable = lib.mkDefault true;

  virtualisation.containers.enable = true;
  virtualisation.docker = {
    enable = true;
  };

  # ---- Secret Service keyring (libsecret) ---------------------------------
  # Gives every machine an `org.freedesktop.secrets` provider so CLI tools that
  # use libsecret (e.g. bkt / the Bitbucket CLI, git credential helpers) store
  # tokens in an unlocked keyring instead of prompting for a passphrase on
  # every call.
  services.gnome.gnome-keyring.enable = true;

  # (Desktop hosts additionally unlock the keyring at the gdm login screen — see
  # hosts/desktop.nix. Graphical login unlock lives there since gdm only exists
  # on desktop hosts.)

  # On headless hosts the systemd unit below is the single source of truth for
  # unlocking, so turn off the console-login PAM unlock that `gnome-keyring.enable`
  # switches on by default. Otherwise a password console login would unlock the
  # keyring with your real password and race the unit's empty-password unlock,
  # leaving a keyring the unit can't open. (Desktop hosts keep it — see gdm above.)
  security.pam.services.login.enableGnomeKeyring =
    lib.mkIf (!config.services.desktopManager.gnome.enable) (lib.mkForce false);

  # How the login keyring gets *unlocked* depends on the host:
  #
  #   * Hosts with a GNOME desktop (gdm) unlock it from your password at
  #     graphical login — handled automatically by the desktop module, nothing
  #     to do here.
  #   * Headless hosts (WSL, bare-metal servers, VMs) have no interactive login
  #     that can unlock it, so we start the secrets service ourselves and unlock
  #     the login keyring with an EMPTY password (no prompt). Trade-off: the
  #     keyring is then encrypted with an empty passphrase — acceptable on a
  #     personal box whose disk is already protected by the host OS, and it's
  #     what "never prompt me" requires.
  #
  # Gate on "no GNOME desktop" (rather than "WSL") so every headless host —
  # artemis, atlas, gateway — gets auto-unlock, while the desktop host
  # (nixosvm) keeps its stronger password-based unlock and never runs this.
  systemd.user.services.gnome-keyring-secrets =
    lib.mkIf (!config.services.desktopManager.gnome.enable) {
      description = "GNOME Keyring secrets service (headless empty-password unlock)";
      wantedBy = [ "default.target" ];
      after = [ "dbus.service" ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "simple";
        # Main process: run the daemon in the foreground in "login" mode,
        # feeding an empty password on stdin so the login keyring is
        # created/unlocked with no prompt.
        ExecStart = pkgs.writeShellScript "gnome-keyring-login" ''
          exec ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --foreground --login < <(printf '\n')
        '';
        # Once the control socket is up, start the secrets component so
        # org.freedesktop.secrets is published on the session bus.
        ExecStartPost = pkgs.writeShellScript "gnome-keyring-start-secrets" ''
          for _ in $(seq 1 50); do
            [ -S "$XDG_RUNTIME_DIR/keyring/control" ] && break
            sleep 0.1
          done
          ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --start --components=secrets
        '';
        Restart = "on-failure";
      };
    };
}

