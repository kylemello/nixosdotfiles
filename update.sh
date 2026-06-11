#!/usr/bin/env bash
# Bump everything to latest and apply it to this machine:
#   1. overlay-pinned packages (infisical, ...) via `nix run .#update-overlays`
#   2. flake inputs (nixpkgs, claude-code, ...) via `nix flake update`
#   3. rebuild / activate
#
# Usage:
#   ./update.sh                 # target = current hostname (NixOS) or you pass a profile
#   ./update.sh gateway         # rebuild a specific NixOS host
#   ./update.sh kmello@iodine   # activate a standalone Home Manager profile
#
# Pass --no-switch to only run the updates and skip the rebuild.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

switch=1
target=""
for arg in "$@"; do
  case "$arg" in
    --no-switch) switch=0 ;;
    *) target="$arg" ;;
  esac
done

echo ">>> Updating overlays (infisical, ...)"
nix run .#update-overlays

echo
echo ">>> Updating flake inputs (nixpkgs, home-manager, claude-code, ...)"
nix flake update

if [ "$switch" -eq 0 ]; then
  echo
  echo "Updates done (--no-switch). Review: git diff -- flake.lock overlays/_sources"
  exit 0
fi

target="${target:-$(hostname)}"
echo
if [ -e /etc/NIXOS ]; then
  echo ">>> Rebuilding NixOS system: .#$target"
  sudo nixos-rebuild switch --flake ".#$target"
else
  echo ">>> Activating Home Manager profile: .#$target"
  home-manager switch --flake ".#$target"
fi
