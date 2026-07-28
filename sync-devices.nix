# Syncthing device IDs, in one place because two modules need them and a
# silent typo in either is expensive: a device ID that does not match is not an
# error anywhere, it just means the two ends never pair and the folders sit at
# "Disconnected" forever.
#
#   hosts/sync-hub.nix  (gateway, the always-on hub) needs artemis + ariane
#   home/sync.nix       (the two endpoints)          needs gateway
#
# NOT SECRET. A Syncthing device ID is a hash of the device's public key; it is
# designed to be exchanged in the clear, and pairing still requires both sides
# to name each other. Safe to commit.
#
# Collected 2026-07-28 with `syncthing device-id --home=<configDir>`. Note
# `--device-id` is a flag that does not exist; `device-id` is a subcommand, and
# it needs a cert.pem, so a never-started config dir must be `syncthing
# generate --home=<same path>`d first. The config dir differs per host and is
# NOT ~/.config/syncthing except on gateway, which sets configDir explicitly:
#
#   gateway  /home/kyle/.config/syncthing                    (hosts/sync-hub.nix)
#   artemis  ${XDG_STATE_HOME:-$HOME/.local/state}/syncthing (HM default, Linux)
#   ariane   $HOME/Library/Application Support/Syncthing     (HM default, darwin)
#
# If a machine is ever reinstalled without preserving that directory it gets a
# NEW identity and this file must be updated — the old ID will simply never
# connect again.
{
  gateway = "VHZC5QI-I5DMC6Z-OSJGFCF-Z7SJIGU-2SI732A-ZRAEFRH-K5P46JR-S5UMTAU";
  artemis = "DH2TYQQ-2T3DZZX-XTHNWJ3-5C6WESU-Q5AAZZY-LMPPE2A-JKARPAO-UIJPGAF";
  ariane = "DQBWPJM-TPSJQKS-77Z2K7R-IEKJ7VV-SS7R7KX-U3XHOBG-XY5N7QP-BPLNFQE";
}
