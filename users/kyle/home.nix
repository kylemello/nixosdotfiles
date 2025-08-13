{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    inputs.catppuccin.homeModules.catppuccin
    ../../home/fish.nix
    ../../home/tmux.nix
    ../../home/git.nix
    ../../home/folders.nix
  ];

  home = {
    username = "kyle";
    homeDirectory = "/home/kyle";
    stateVersion = "25.05";

    sessionVariables = {
      MANPAGER="nvim +Man!";
      EDITOR = "nvim";
      VISUAL = "nvim";
      DOCKER_HOST = "unix:///run/user/1000/podman/podman.sock";
    };

    shellAliases = {
      ll="eza -laghF --icons --time-style=long-iso --group-directories-first";
      l="eza -lghF --icons --time-style=long-iso --group-directories-first";
      mysql="mysql --skip-ssl";
      yolo="git commit -m \"$(curl -s https://whatthecommit.com/index.txt)\"";
      cd="z";
    };

    packages = with pkgs; [
      bat
      bootdev-cli
      cargo
      delta
      deno
      dive
      duf
      dust
      eza
      fastfetch
      fzf
      gemini-cli
      gcc
      gh
      go
      htop
      jdk
      jq
      lazydocker
      lazygit
      neovim
      nodejs
      nodePackages."@angular/cli"
      pnpm
      python3
      ripgrep
      rustc
      tealdeer
      tmux
      tree-sitter
      unzip
      upterm
      uv
      xh
      yazi
      yt-dlp
      zoxide
    ];
  };

  catppuccin = {
    enable = true;
    flavor = "mocha";
  };

  programs.home-manager.enable = true;
}
