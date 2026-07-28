{ config, lib, pkgs, ... }:

# Syncthing on the two endpoints (artemis, ariane). The always-on hub is
# gateway, configured as a SYSTEM service in hosts/sync-hub.nix — this module
# is the client half and must never run there. See the `enable` description.
let
  cfg = config.kyle.sync;
  deviceIds = import ../sync-devices.nix;
in
{
  options.kyle.sync = {
    enable = lib.mkEnableOption ''
      Syncthing for ~/notes and ~/scratch, replicated through the gateway hub.

      Off by default and enabled per-host in home/wsl.nix and home/darwin.nix,
      NOT in users/kyle/home.nix. That profile is imported by all four NixOS
      hosts, and enabling it there would hand gateway a SECOND Syncthing on top
      of the system one in hosts/sync-hub.nix. That failure is silent in the
      worst way -- eval and rebuild both succeed -- and it is destructive:

        * Home Manager's Linux config-dir probe picks
          ''${XDG_CONFIG_HOME:-$HOME/.config}/syncthing whenever
          ~/.local/state/syncthing/config.xml is absent, which is exactly the
          configDir the system instance uses. Two daemons, one database, one
          device identity.
        * Both want :8384 and :22000; the system instance already holds them,
          so the user unit crash-loops.
        * Worst, syncthing-init does not depend on its own daemon starting. It
          reads the API key straight out of that shared config.xml and talks to
          guiAddress -- i.e. to the RUNNING HUB -- with --retry 1000. With
          overrideDevices/overrideFolders it POSTs the client's definition of
          `notes` and `scratch` over the hub's (replacing them, versioning
          block and all) and DELETEs every device not in the client's list.
          The hub's staggered version history and both endpoints are gone.

      hosts/sync-hub.nix asserts against this, so the mistake fails the build
    '';

    host = lib.mkOption {
      type = lib.types.str;
      # MUST have a default: users/kyle/home.nix reaches all four NixOS hosts,
      # and an option with no default is a hard eval error the moment the
      # module system touches it, even on hosts that leave `enable` off.
      default = "";
      description = ''
        This machine's key in sync-devices.nix. Set alongside kyle.wip.host in
        home/wsl.nix and home/darwin.nix. Only used to check that this host has
        a known identity — the folders are shared with the hub, not by name.
      '';
      example = "artemis";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.host != "";
        message = "kyle.sync.enable is on but kyle.sync.host is empty; set it to "
          + "this machine's key in sync-devices.nix.";
      }
      {
        assertion = deviceIds ? ${cfg.host};
        message = "kyle.sync.host = \"${cfg.host}\" has no entry in sync-devices.nix. "
          + "Collect it with `syncthing device-id --home=<configDir>` and add it there; "
          + "an unknown endpoint would never be let in by the hub.";
      }
      {
        # Belt and braces for the scenario the `enable` text describes. The
        # authoritative guard is the assertion in hosts/sync-hub.nix, which sees
        # the system service; this one catches the same mistake from this side.
        assertion = cfg.host != "gateway";
        message = "gateway runs the SYSTEM Syncthing (hosts/sync-hub.nix). A Home "
          + "Manager Syncthing there would share its config directory and rewrite "
          + "the hub's configuration over the REST API. Enable home/sync.nix from "
          + "home/wsl.nix / home/darwin.nix only.";
      }
    ];

    # Scope is deliberately narrow: loose files only. Repos go through `wip`
    # (home/wip.nix) and config goes through the flake, so no .git directory
    # ever enters a Syncthing folder and the lock-file hazard cannot arise.
    services.syncthing = {
      enable = true;

      # Both default to true; stated explicitly because they are the reason
      # pairing must go through this file. Anything paired by hand in the GUI is
      # DELETEd on the next activation ("Deleting stale device: ..." in the
      # journal). Do not hand-pair — add the ID to sync-devices.nix instead.
      overrideDevices = true;
      overrideFolders = true;

      settings = {
        # Remote peers only. The local device is not listed, matching the hub:
        # merge-syncthing-config DELETEs it as "stale" on every run and
        # Syncthing's config validation immediately re-adds it with its name
        # intact. Verified on gateway, which has run this way since Task 2 —
        # the journal shows the delete each activation and config.xml still
        # carries `name="gateway"`. Harmless churn, not worth diverging for.
        devices.gateway.id = deviceIds.gateway;

        # Star topology: both endpoints talk only to the hub, never to each
        # other, so neither has to be awake for the other to catch up.
        #
        # No `versioning` here on purpose. Versioning is per-device in
        # Syncthing, and the retention copies live on the hub
        # (hosts/sync-hub.nix: staggered, 30d for notes / 7d for scratch).
        # Keeping .stversions off the laptops is the point.
        #
        # ~/notes and ~/scratch are created on every machine by
        # home/folders.nix, so they exist before Syncthing first starts.
        folders = {
          "notes" = {
            path = "${config.home.homeDirectory}/notes";
            devices = [ "gateway" ];
          };
          "scratch" = {
            path = "${config.home.homeDirectory}/scratch";
            devices = [ "gateway" ];
          };
        };

        options.urAccepted = -1; # decline usage reporting
      };
    };
  };
}
