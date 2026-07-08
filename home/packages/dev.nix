{ pkgs, ... }:

{
  home.packages = with pkgs; [
    air # Live reload for golang
    ansible
    awscli2
    azure-cli
    bitbucket-cli
    bun
    cargo
    deno
    devenv
    docker-buildx
    dolt
    emacs-nox
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
    sqlite
    terraform
    tokei
    tree-sitter
    uv
  ];
}
