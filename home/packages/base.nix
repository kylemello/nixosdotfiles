{ pkgs, ... }:

{
  home.packages = with pkgs; [
    bat
    delta
    duf
    dust
    eza
    fzf
    htop
    jq
    neovim
    ripgrep
    tealdeer
    tmux
    unzip
    xh
    zoxide
  ];
}
