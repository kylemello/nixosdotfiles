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

  outputs = { self, nixpkgs, flake-utils, home-manager, ... }@inputs:
  let
    mkNixOS = modules: nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [ home-manager.nixosModules.home-manager ] ++ modules;
    };
  in {
    # This is now at the top level, where nixos-rebuild expects it.
    nixosConfigurations = {
      artemis = mkNixOS [ ./machines/artemis/configuration.nix ];
      atlas = mkNixOS [ ./machines/atlas/configuration.nix ];
      nixosvm = mkNixOS [ ./machines/nixosvm/configuration.nix ];
    };
  } // flake-utils.lib.eachDefaultSystem (system: # The '//' operator merges the two sets.
    let
      # The `system` variable from flake-utils is now used correctly.
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      # This part remains inside the loop, so it's generated for each architecture.
      homeConfigurations = {
        "kyle-work" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [ ./users/kyle/work-kyle.nix ];
          extraSpecialArgs = { inherit inputs; };
        };
        "kmello-work" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [ ./users/kyle/work-kmello.nix ];
          extraSpecialArgs = { inherit inputs; };
        };
      };
    }
  );
}
