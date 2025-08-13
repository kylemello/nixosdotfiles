{ config, pkgs, ... }:

{
  home.username = "kyle";
  home.homeDirectory = "/home/kyle";

  home.sessionVariables = {
    MANPAGER="nvim +Man!";
    EDITOR = "nvim";
    VISUAL = "nvim";
    DOCKER_HOST = "unix:///run/user/1000/podman/podman.sock";
  };

  catppuccin = {
    enable = true;
    flavor = "mocha";
  };

  home.shellAliases = {
    ll="eza -laghF --icons --time-style=long-iso --group-directories-first";
    l="eza -lghF --icons --time-style=long-iso --group-directories-first";
    mysql="mysql --skip-ssl";
    yolo="git commit -m \"$(curl -s https://whatthecommit.com/index.txt)\"";
    cd="z";
  };

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
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


  home.stateVersion = "24.11";

  programs.home-manager.enable = true;
}
