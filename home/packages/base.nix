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
    neovim-unwrapped
    ripgrep
    tealdeer
    unzip
    xh
    zoxide
  ];
}
