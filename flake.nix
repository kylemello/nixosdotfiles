{
  description = "A flake for my personal configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-wsl = {
      url = "github:nix-community/nixos-wsl";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    catppuccin = {
      url = "github:catppuccin/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Always-fresh Claude Code (upstream refreshes hourly). Intentionally NOT
    # following nixpkgs so we hit their Cachix-cached prebuilt binaries instead
    # of rebuilding locally on every version bump.
    claude-code.url = "github:sadjow/claude-code-nix";
  };

  outputs = inputs@{ self, nixpkgs, flake-utils, home-manager, nixos-wsl, catppuccin, claude-code, ... }:
    let
      overlays = [
        (import ./overlays)
        claude-code.overlays.default
      ];

      mkNixOS = { system, machineModule }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            # Apply overlays to nixpkgs
            ({ config, pkgs, ... }: {
              nixpkgs.overlays = overlays;
            })
            home-manager.nixosModules.home-manager
            ({ ... }: {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs; };
            })
            nixos-wsl.nixosModules.wsl
            machineModule
          ];
        };
    in
    flake-utils.lib.eachSystem flake-utils.lib.allSystems (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = overlays;
          config.allowUnfree = true;
        };
      in {
        legacyPackages = pkgs // {
          homeConfigurations = {
            "kyle-work" = home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [ ./users/kyle/work-kyle.nix ];
              extraSpecialArgs = { inherit inputs; };
            };
            "kmello@iodine" = home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [ ./users/kyle/work-kmello.nix catppuccin.homeModules ];
              extraSpecialArgs = { inherit inputs; };
            };
          };
        };

        # `nix run .#update-overlays` bumps every overlay to its latest
        # upstream version. It auto-discovers overlays/*.update.sh (same spirit
        # as overlays/default.nix) and runs each, rewriting overlays/_sources/.
        apps.update-overlays =
          let
            runner = pkgs.writeShellScriptBin "update-overlays" ''
              set -euo pipefail
              export PATH="${pkgs.lib.makeBinPath (with pkgs; [ curl jq coreutils gnugrep gnused git ])}:$PATH"
              export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              root="$(git rev-parse --show-toplevel)"
              overlays_dir="$root/overlays"
              shopt -s nullglob
              any=0
              for updater in "$overlays_dir"/*.update.sh; do
                any=1
                name="$(basename "$updater" .update.sh)"
                echo ">>> Updating overlay: $name"
                bash "$updater" "$overlays_dir/_sources/$name.json"
              done
              if [ "$any" -eq 0 ]; then
                echo "No overlays/*.update.sh updaters found." >&2
                exit 1
              fi
              git -C "$root" add overlays/_sources
              echo
              echo "Overlays bumped. Review with: git diff -- overlays/_sources"
            '';
          in {
            type = "app";
            program = "${runner}/bin/update-overlays";
          };
      }
    )
    //
    {
      nixosConfigurations = {
        artemis = mkNixOS {
          system = "x86_64-linux";
          machineModule = ./machines/artemis/configuration.nix;
        };
        atlas = mkNixOS {
          system = "x86_64-linux";
          machineModule = ./machines/atlas/configuration.nix;
        };
        gateway = mkNixOS {
          system = "x86_64-linux";
          machineModule = ./machines/gateway/configuration.nix;
        };
        nixosvm = mkNixOS {
          system = "x86_64-linux";
          machineModule = ./machines/nixosvm/configuration.nix;
        };
      };
    };
}
