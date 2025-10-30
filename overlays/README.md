# Package Overlays

This directory contains Nix overlays for overriding package versions or adding custom packages.

## What are Overlays?

Overlays allow you to modify or extend the nixpkgs package set. This is useful when you want:
- Latest versions of packages before they're updated in nixpkgs
- Custom patches or build options
- Packages not yet in nixpkgs

## How to Add an Override

### Method 1: Override from a Newer Nixpkgs Commit

Create a file like `overlays/latest-packages.nix`:

```nix
self: super: {
  # Override a package with a version from a specific nixpkgs commit
  neovim = super.neovim.overrideAttrs (oldAttrs: rec {
    version = "0.10.0";
    src = super.fetchFromGitHub {
      owner = "neovim";
      repo = "neovim";
      rev = "v${version}";
      sha256 = "sha256-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX";
    };
  });
}
```

### Method 2: Use a Different Nixpkgs Input

In your `flake.nix`, you can add an unstable channel and cherry-pick packages:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  # Then in your overlay:
  overlays = [
    (final: prev: {
      neovim = inputs.nixpkgs-unstable.legacyPackages.${prev.system}.neovim;
    })
  ];
}
```

### Method 3: Build from Latest Source

```nix
self: super: {
  # Build a package directly from the latest git source
  mypackage = super.mypackage.overrideAttrs (oldAttrs: {
    src = super.fetchFromGitHub {
      owner = "username";
      repo = "reponame";
      rev = "main";  # or a specific commit hash
      sha256 = super.lib.fakeSha256;  # Run once to get the real hash
    };
  });
}
```

### Method 4: Simple Version Override

```nix
self: super: {
  # Just change the version while keeping the same derivation
  ripgrep = super.ripgrep.overrideAttrs (oldAttrs: rec {
    version = "14.1.0";
    src = super.fetchFromGitHub {
      owner = "BurntSushi";
      repo = "ripgrep";
      rev = version;
      hash = "sha256-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX";
    };
  });
}
```

## File Organization

- `default.nix` - Main entry point that imports all overlays
- `latest-packages.nix` - (Example) Override packages to latest versions
- `custom-packages.nix` - (Optional) Add completely new packages

## Getting SHA256 Hashes

When you need to get the correct hash for a source:

1. Use `lib.fakeSha256` or `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=` temporarily
2. Try to build the package: `nix build .#<package>`
3. Nix will fail and show you the correct hash
4. Replace the fake hash with the real one

## Tips

- Start with small overrides and test them
- Use `nix flake show` to see available packages
- Use `nix search nixpkgs <package>` to find package names
- Check the nixpkgs source on GitHub to see how packages are defined
- Keep overlays focused and organized by purpose
