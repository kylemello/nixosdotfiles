{ lib, ... }:

# TrueNAS NFS shares: Plex media library, the k3s app storage (pancakes
# configs), and Meteor scratch space. Mounted on first access via systemd
# automount rather than at boot, so a NAS that's down never holds up booting —
# `nofail` plus the short mount timeout make a failed mount a fast error
# instead of a hang.
#
# vers=3,tcp,nolock,noresvport is the option set verified against this export;
# don't change it to fix a failed mount. The k3s-storage export is
# host-restricted on the TrueNAS side, so a host missing from its allow list
# gets "access denied" until it's added there. media and meteor are open to
# the LAN.
let
  nas = "10.11.12.10";
  mkNfs = export: {
    device = "${nas}:${export}";
    fsType = "nfs";
    options = [
      "vers=3"
      "tcp"
      "nolock"
      "noresvport"
      "x-systemd.automount"
      "x-systemd.mount-timeout=10s"
      "_netdev"
      "nofail"
    ];
  };
in
{
  boot.supportedFilesystems = [ "nfs" ];

  fileSystems = lib.mapAttrs' (name: export: lib.nameValuePair "/mnt/tn/${name}" (mkNfs export)) {
    media = "/mnt/Infinity/media";
    k3s-storage = "/mnt/Infinity/k3s-storage";
    # Non-redundant two-disk stripe: fast scratch space, nothing important.
    meteor = "/mnt/Meteor/scratch";
  };
}
