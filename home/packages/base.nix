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
    # k9s is NOT here — it comes in via home/k9s.nix (programs.k9s), which the
    # catppuccin port requires in order to theme it.
    neovim-unwrapped
    ripgrep
    tealdeer
    unzip
    zip
    wget
    xh
    yq-go
    zoxide
  ];
}
