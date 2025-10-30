# This file imports and composes all overlays in this directory
# Overlays allow you to override or add packages to nixpkgs
#
# To add a new package override:
# 1. Create a new file like overlays/package-name.nix
# 2. Define your overlay as: self: super: { package-name = ...; }
# 3. This file will automatically discover and import it

self: super:
let
  # Get the directory where this file is located
  overlayDir = ./.;

  # Use lib from super (nixpkgs)
  inherit (super) lib;

  # Get all .nix files in this directory except default.nix
  overlayFiles = builtins.filter
    (name: name != "default.nix" && lib.hasSuffix ".nix" name)
    (builtins.attrNames (builtins.readDir overlayDir));

  # Import each overlay file and apply it
  overlays = map (f: import (overlayDir + "/${f}")) overlayFiles;

  # Compose all overlays into a single overlay
  # Each overlay is a function (self: super: { ... })
  # We apply them sequentially so later overlays can override earlier ones
  composed = lib.foldl' (acc: overlay: acc // (overlay self super)) {} overlays;
in
  composed
