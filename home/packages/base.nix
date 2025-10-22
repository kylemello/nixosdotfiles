{ pkgs, ... }:

{
  home.packages = with pkgs; [
    bat
    delta
    duf
    dust
    eza
    fzf
    gnupg
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
