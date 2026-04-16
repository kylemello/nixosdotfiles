{ pkgs, ... }:

{
  home.packages = with pkgs; [
    air # Live reload for golang
    ansible
    azure-cli
    cargo
    deno
    devenv
    docker-buildx
    dolt
    gcc
    gh
    glab
    gnumake
    go
    infisical
    jdk
    kubectl
    kubernetes-helm
    lazydocker
    lazygit
    nodejs_24
    php
    phpactor
    pkg-config
    pnpm
    ruby
    rustc
    terraform
    tokei
    tree-sitter
    uv
  ];
}
