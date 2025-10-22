{ pkgs, ... }:

{
  home.packages = with pkgs; [
    air # Live reload for golang
    azure-cli
    cargo
    deno
    devenv
    docker-buildx
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
    php
    phpactor
    ruby
    rustc
    tree-sitter
    uv
  ];
}
