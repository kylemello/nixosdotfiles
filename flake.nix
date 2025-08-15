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
  };

  outputs = inputs@{ self, nixpkgs, flake-utils, home-manager, nixos-wsl, catppuccin, ... }:
    let
      mkNixOS = { system, machineModule }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
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
        pkgs = nixpkgs.legacyPackages.${system};
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
        nixosvm = mkNixOS {
          system = "x86_64-linux";
          machineModule = ./machines/nixosvm/configuration.nix;
        };
      };
    };
}
