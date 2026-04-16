{ pkgs, ... }:

{
  home.packages = with pkgs; [
    bat
    croc
    delta
    dig
    duf
    dust
    eza
    fzf
    gnupg
    htop
    jq
    k9s
    neovim-unwrapped
    ripgrep
    tealdeer
    unzip
    xh
    zoxide
  ];
}
