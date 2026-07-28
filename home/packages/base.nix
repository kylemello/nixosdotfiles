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
    fd
    fzf
    gnupg
    htop
    jq
    k9s
    neovim-unwrapped
    ripgrep
    tealdeer
    unzip
    wget
    xh
    yq-go
    zoxide
  ];
}
