{ pkgs, ... }:

{
  home.packages = with pkgs; [
    air # Live reload for golang
    cargo
    deno
    devenv
    doppler
    gcc
    gh
    gnumake
    go
    jdk
    lazydocker
    lazygit
    nodejs
    pkg-config
    pnpm
    ruby
    rustc
    tree-sitter
    uv
  ];
}
