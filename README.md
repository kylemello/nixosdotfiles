# My NixOS & Home Manager Dotfiles

This repository contains my personal configurations for multiple machines, managed declaratively using [Nix](https://nixos.org/) and [Nix Flakes](https://nixos.wiki/wiki/Flakes). The goal is to create a single, version-controlled source of truth for all my development environments, whether they are running NixOS, another Linux distribution, or even WSL.

This setup is designed to be **modular**, **reusable**, and **multi-architecture**, allowing it to scale easily as new machines and configurations are added.

---

## Core Philosophy

The structure of this repository is built on a clear separation of concerns, dividing configurations into three distinct categories:

1. **Hosts (`hosts/`)**: These are reusable system-level modules or "features." They define _what_ can be configured on a system (e.g., a graphical desktop environment, a server setup, WSL integration).
2. **Machines (`machines/`)**: These are specific NixOS system definitions. They define _where_ host features are applied, combining them with machine-specific details like hostname and hardware profiles.
3. **Users (`users/` & `home/`)**: These are user-level configurations managed by [Home Manager](https://github.com/nix-community/home-manager). They define _who_ is using the machine and what their personal environment (dotfiles, packages, shell) looks like.

---

## Directory Structure

Here is a breakdown of the key files and directories and their purpose.

```
.
├── flake.nix         # The central entry point for the entire configuration.
├── flake.lock        # The lockfile ensuring reproducible builds.
├── README.md         # This file.
|
├── hosts/            # Reusable NixOS system-level modules.
│   ├── common.nix    # Base settings for ALL NixOS systems (SSH, time, etc.).
│   ├── desktop.nix   # Settings for graphical desktops (display manager, sound).
│   └── wsl.nix       # NixOS settings specific to WSL environments.
|
├── home/             # Reusable Home Manager user-level modules.
│   ├── common.nix    # Base settings for my user (essential packages, aliases).
│   ├── git.nix       # All Git-related configurations.
│   ├── tmux.nix      # All tmux-related configurations.
│   └── wsl.nix       # User-level settings specific to WSL (e.g., using ssh.exe).
|
├── machines/         # Definitions for specific NixOS machines.
│   └── artemis/      # A directory for the machine with hostname 'artemis'.
│       └── configuration.nix # Imports modules from hosts/ and sets machine details.
|
├── overlays/         # Package overlays for version overrides and customizations.
│   ├── README.md     # Documentation on how to add package overrides.
│   └── latest-packages.nix # Override packages to latest versions.
|
└── users/            # Top-level user profiles.
    └── kyle/
        ├── home.nix            # Main profile for all my NixOS machines.
        └── work-kmello.nix     # Standalone profile for a non-NixOS work machine.
```

---

## How It Works

### The `flake.nix` File

The `flake.nix` is the heart of the system. It performs several critical functions:

- **Defines Inputs**: It lists all external dependencies, such as `nixpkgs`, `home-manager`, and other community flakes like `catppuccin`.
- **Uses `flake-utils`**: It uses the `flake-utils.lib.eachDefaultSystem` helper to automatically generate configurations for multiple CPU architectures (`x86_64-linux`, `aarch64-linux`, etc.), making the setup portable.
- **Defines Outputs**: It exposes two main outputs:
  - `nixosConfigurations`: A set of complete NixOS systems, built by combining a `machines/` definition with the `home-manager` module.
  - `homeConfigurations`: A set of standalone Home Manager profiles that can be deployed on any machine with Nix installed, regardless of the OS.

### Building a NixOS System

A complete NixOS system (like `artemis`) is built as follows:

1. The `flake.nix` file points to `machines/artemis/configuration.nix`.
2. `machines/artemis/configuration.nix` defines the machine's `hostname` and declares its primary user (`kyle`).
3. It then `imports` the necessary system-level modules from `hosts/` (e.g., `hosts/common.nix` and `hosts/wsl.nix`).
4. Finally, it imports the user's Home Manager profile from `users/kyle/home.nix`.
5. The `users/kyle/home.nix` profile, in turn, imports all the desired user-level modules from `home/` (like `git.nix`, `tmux.nix`, etc.) and intelligently includes `home/wsl.nix` if it detects it's on a WSL system.

This creates a top-down declarative structure where everything is explicitly defined and composed from smaller, reusable parts.

---

## Workflow

### Adding a New NixOS Machine

1. Create a new directory for your machine: `mkdir -p machines/new-machine`.
2. Create `machines/new-machine/configuration.nix`. In this file, set the `hostname`, define the `users`, and `import` the required modules from `hosts/` and `users/`.
3. Add the new machine to the `nixosConfigurations` set in your `flake.nix`.
4. On the new machine, run `sudo nixos-rebuild switch --flake .#new-machine` to build and activate the configuration.

### Adding a Standalone (Non-NixOS) Machine

1. Create a new profile file, e.g., `users/kyle/my-new-server.nix`.
2. In this file, explicitly define `home.username` and `home.homeDirectory`. Import all the desired modules from the `home/` directory.
3. Add the new profile to the `homeConfigurations` set in your `flake.nix`.
4. On the target machine (which must have Nix installed), run `home-manager switch --flake .#my-new-server` to apply your user environment.

### Adding a New Program Configuration

1. Create a new file for the program in the `home/` directory (e.g., `home/neovim.nix`).
2. Add all the Home Manager configuration for that program into the new file.
3. Import your new module in any user profile that needs it (e.g., add `../../home/neovim.nix` to the `imports` list in `users/kyle/home.nix`).
4. Re-run the appropriate build command (`nixos-rebuild` or `home-manager switch`) to apply the changes.

### Overriding Package Versions

If you need the latest version of a package before it's available in the stable nixpkgs channel, you can use overlays:

1. Edit `overlays/latest-packages.nix` to add your package override.
2. The overlay will automatically be applied to all machines and home-manager configurations.
3. See `overlays/README.md` for detailed examples and methods.

**Common use cases:**
- Getting bleeding-edge versions of development tools
- Applying custom patches to packages
- Using packages from nixpkgs-unstable while staying on stable
- Building packages from the latest git source

**Example:** To override neovim to version 0.10.0:

```nix
# In overlays/latest-packages.nix
self: super: {
  neovim = super.neovim.overrideAttrs (oldAttrs: rec {
    version = "0.10.0";
    src = super.fetchFromGitHub {
      owner = "neovim";
      repo = "neovim";
      rev = "v${version}";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
  });
}
```

Then rebuild with `sudo nixos-rebuild switch --flake .#<machine-name>` or `home-manager switch --flake .#<profile-name>`.
