{ config, pkgs, ... }:

{
  home.username = "kyle";
  home.homeDirectory = "/home/kyle";

  home.sessionVariables = {
    DOCKER_HOST = "unix:///run/user/1000/podman/podman.sock";
  };

  home.shellAliases = {
    ll="eza -laghF --icons --time-style=long-iso --group-directories-first";
    l="eza -lghF --icons --time-style=long-iso --group-directories-first";
    ghcp="gh copilot";
    mysql="mysql --skip-ssl";
    yolo="git commit -m \"$(curl -s https://whatthecommit.com/index.txt)\"";
    cd="z";
    cat="bat";
  };

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    bat
    delta
    deno
    dive
    duf
    dust
    eza
    fastfetch
    fzf
    gcc
    gh
    htop
    jq
    lazydocker
    lazygit
    nodejs
    pnpm
    python3
    ripgrep
    tealdeer
    tmux
    tree-sitter
    unzip
    uv
    xh
    yazi
    zoxide
  ];


  home.stateVersion = "25.05";

  programs.home-manager.enable = true;
}
