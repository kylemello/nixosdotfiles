{
  description = "Kyle's Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    catppuccin.url = "github:catppuccin/nix";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, catppuccin, ... }: 
    let
      system = "x86_64-linux";
      username = "kyle";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      homeConfigurations."${username}" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;

        # Home Manager modules
        modules = [
          ./home.nix

          ./tmux.nix
          ./git.nix
          ./nix-index.nix
          ./fish.nix
          ./folders.nix
          ./wsl.nix

          catppuccin.homeModules.catppuccin
        ];
      };
    };
}

