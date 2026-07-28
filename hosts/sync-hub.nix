{ config, lib, pkgs, ... }:

# Always-on sync hub. Imported only by gateway. Both endpoints (artemis,
# ariane) talk to this box rather than to each other, so neither has to be
# awake for the other to catch up.
{
  # --- wip snapshot storage --------------------------------------------------
  # Bare repos created on demand by the `wip` script over SSH (home/wip.nix).
  # 0700 under kyle's home: unreadable by seth (no sudo) and by CI jobs
  # (ProtectHome masks /home entirely — see machines/gateway/configuration.nix).
  #
  # notes/scratch below are declared here (rather than left to
  # home/folders.nix) because Syncthing needs them to exist at first start,
  # and home/folders.nix isn't updated to create them until a later task —
  # declaring them here removes that ordering dependency entirely. 0755 (not
  # 0700 like wip) since these are meant to be readable, matching their
  # eventual home/folders.nix ownership.
  systemd.tmpfiles.rules = [
    "d /home/kyle/wip 0700 kyle users -"
    "d /home/kyle/wip/_manifest 0700 kyle users -"
    "d /home/kyle/notes 0755 kyle users -"
    "d /home/kyle/scratch 0755 kyle users -"
  ];

  # --- Atuin: shell history server ------------------------------------------
  # Clients point here instead of api.atuin.sh (home/atuin.nix).
  services.atuin = {
    enable = true;
    host = "0.0.0.0";
    port = 8888;
    # Registration is opened for the initial `atuin register` on each machine,
    # then should be flipped to false and rebuilt. Two clients, one user.
    openRegistration = true;
    openFirewall = true;
  };

  # --- Syncthing: loose files ------------------------------------------------
  # Scope is deliberately small: ~/notes and ~/scratch only. Repos go through
  # `wip`, config goes through the flake.
  #
  # GUI port. openDefaultPorts does not cover it, so it is opened explicitly.
  networking.firewall.allowedTCPPorts = [ 8384 ];

  services.syncthing = {
    enable = true;
    user = "kyle";
    group = "users";
    dataDir = "/home/kyle";
    configDir = "/home/kyle/.config/syncthing";
    guiAddress = "0.0.0.0:8384";
    openDefaultPorts = true;

    # The GUI is bound wide (0.0.0.0), not loopback-only, and openDefaultPorts
    # doesn't cover the GUI port anyway (only 22000/tcp+udp and 21027/udp) —
    # that's opened above. gateway has a second human user, seth, with an SSH
    # shell and no sudo (see machines/gateway/configuration.nix, and Task 1,
    # which exists specifically to fence him off from /home), so an
    # unauthenticated GUI/REST API here would be reachable by him over
    # loopback today and the whole LAN/Teleport once the port is open. Auth is
    # therefore mandatory, not optional. The password file is created by hand
    # at deploy time, root-owned, outside git:
    #   sudo install -Dm400 /dev/stdin /var/lib/syncthing/gui-password
    # (paste the password, then Ctrl-D).
    guiPasswordFile = "/var/lib/syncthing/gui-password";

    settings = {
      gui.user = "kyle";
      options.urAccepted = -1; # decline usage reporting

      folders = {
        "notes" = {
          path = "/home/kyle/notes";
          # TODO(Task 12): restore once device IDs are known
          # devices = [ "artemis" "ariane" ];
          versioning = {
            type = "staggered";
            params.maxAge = "2592000"; # 30 days, in seconds
          };
        };
        "scratch" = {
          path = "/home/kyle/scratch";
          # TODO(Task 12): restore once device IDs are known
          # devices = [ "artemis" "ariane" ];
          versioning = {
            type = "staggered";
            params.maxAge = "604800"; # 7 days
          };
        };
      };
    };
  };
}
