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
    infisical
    jdk
    lazydocker
    lazygit
    nodePackages."@angular/cli"
    nodejs
    php
    phpactor
    pkg-config
    pnpm
    ruby
    rustc
    tree-sitter
    uv
  ];
}
