{ config, lib, pkgs, ... }:

# Always-on sync hub. Imported only by gateway. Both endpoints (artemis,
# ariane) talk to this box rather than to each other, so neither has to be
# awake for the other to catch up.
let
  deviceIds = import ../sync-devices.nix;
in
{
  # This box runs the SYSTEM Syncthing configured below. A Home Manager user
  # Syncthing here would be a silent disaster rather than a conflict: HM's
  # Linux probe resolves to ${XDG_CONFIG_HOME:-$HOME/.config}/syncthing, which
  # is precisely the configDir set below, so the user instance's
  # syncthing-init would read THIS instance's API key and — with
  # overrideDevices/overrideFolders on — POST the client's folder definitions
  # over these, discarding the versioning blocks and DELETEing artemis and
  # ariane. Both eval and rebuild would report success.
  #
  # users/kyle/home.nix is imported by all four NixOS hosts, so home/sync.nix
  # is imported there for its options and enabled only in home/wsl.nix and
  # home/darwin.nix. Assertions are forced through system.build.toplevel, so a
  # clean drvPath eval is proof this never regressed.
  assertions = [
    {
      assertion = !(config.home-manager.users.kyle.services.syncthing.enable or false);
      message = "gateway runs the system Syncthing (hosts/sync-hub.nix); a Home Manager "
        + "user Syncthing would share /home/kyle/.config/syncthing and rewrite this "
        + "config over the REST API. Enable home/sync.nix from home/wsl.nix / "
        + "home/darwin.nix, not users/kyle/home.nix.";
    }
  ];

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
    # CLOSED. This listens on 0.0.0.0:8888 with openFirewall below, so an open
    # registration endpoint is reachable from the whole LAN (and from seth, who
    # has a shell on this box). It was opened only for the one-time `atuin
    # register` on each client. Two clients, one user — nobody else should ever
    # be able to create an account here.
    #
    # If a third client ever needs to register: flip this to true, rebuild, run
    # `atuin register` on that machine, then flip it straight back and rebuild
    # again. Do not leave it open between those two steps for longer than the
    # registration takes.
    openRegistration = false;
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
    # therefore mandatory, not optional.
    #
    # The password file is created by hand at deploy time, outside git, and
    # MUST be owned by the syncthing user (kyle), not root: syncthing-init.service
    # runs merge-syncthing-config as services.syncthing.user (kyle), and a
    # root-owned file fails that step with "Permission denied" — silently, in
    # the sense that the unit still reports active and the file still exists
    # with sane-looking permissions, but no <password> element ever gets
    # written and the GUI ends up authenticating nobody. Typing the password
    # in interactively also doesn't work over `ssh host "bash -lc '...'"`
    # (no interactive stdin => a 0-byte file, which fails the same silent
    # way); generate it instead:
    #   head -c 18 /dev/urandom | base64 | sudo tee /var/lib/syncthing/gui-password >/dev/null
    #   sudo chown kyle:users /var/lib/syncthing/gui-password
    #   sudo chmod 400 /var/lib/syncthing/gui-password
    #   sudo systemctl restart syncthing-init
    # A full `nixos-rebuild switch` is not needed for a password change —
    # syncthing-init.service runs merge-syncthing-config and re-applies it on
    # restart. The file existing is NOT proof it applied: check
    # `journalctl -u syncthing-init` for the absence of "Permission denied".
    guiPasswordFile = "/var/lib/syncthing/gui-password";

    settings = {
      gui.user = "kyle";
      options.urAccepted = -1; # decline usage reporting

      # overrideDevices defaults to true: on every activation, Syncthing
      # deletes any paired device not declared under settings.devices here
      # (observed in the journal as "Deleting stale device: <id>..."). Now that
      # "artemis"/"ariane" are declared, any device paired out-of-band (e.g.
      # manually through the GUI) will be dropped the next time this module is
      # applied — pairing must go through sync-devices.nix.
      #
      # The hub's own ID is deliberately absent: merge-syncthing-config deletes
      # it as stale on every run and Syncthing's config validation re-adds it
      # immediately with its name intact (visible in `journalctl -u
      # syncthing-init` today, and config.xml still carries name="gateway").
      # Declaring remote peers only keeps this file symmetrical with
      # home/sync.nix.
      devices = {
        artemis.id = deviceIds.artemis;
        ariane.id = deviceIds.ariane;
      };

      folders = {
        "notes" = {
          path = "/home/kyle/notes";
          devices = [ "artemis" "ariane" ];
          # Versioning is per-device, so these retention copies exist only
          # here. The endpoints deliberately declare none — see home/sync.nix.
          versioning = {
            type = "staggered";
            params.maxAge = "2592000"; # 30 days, in seconds
          };
        };
        "scratch" = {
          path = "/home/kyle/scratch";
          devices = [ "artemis" "ariane" ];
          versioning = {
            type = "staggered";
            params.maxAge = "604800"; # 7 days
          };
        };
      };
    };
  };
}
