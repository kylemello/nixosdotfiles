{
  description = "Kyle's Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    catppuccin.url = "github:catppuccin/nix";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-wsl = {
      url = "github:nix-community/nixos-wsl";
    };
  };

  outputs = { self, nixpkgs, home-manager, catppuccin, nixos-wsl, ... }:
    let
      system = "x86_64-linux";
      username = "kyle";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;
      wsl-support = import ./wsl-support.nix { inherit lib pkgs; };
    in {
      nixosConfigurations."nixos-wsl" = lib.nixosSystem {
        inherit system;
        specialArgs = {
          wsl = true;
        };
        modules = [
          ./hosts/nixos-wsl/configuration.nix
          nixos-wsl.nixosModules.wsl
          ({ config, pkgs, lib, wsl, ... }: lib.mkIf wsl wsl-support.nixos)
        ];
      };
      homeConfigurations."${username}" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          wsl = false;
        };

        # Home Manager modules
        modules = [
          ./home.nix

          ./tmux.nix
          ./git.nix
          ./nix-index.nix
          ./fish.nix
          ./folders.nix

          catppuccin.homeModules.catppuccin
          ({ config, pkgs, lib, wsl, ... }: lib.mkIf wsl wsl-support.home-manager)
        ];
      };
    };
}

