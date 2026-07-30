{ pkgs, ... }:

{
  home.packages = with pkgs; [
    _1password-cli
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
    gitleaks
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
    openssl
    opentofu
    php
    phpactor
    pkg-config
    pnpm
    ruby
    rustc
    sqlc # was a `go install` into ~/go/bin on artemis only
    sqlite
    tea
    terraform
    tokei
    tree-sitter
    # Browser-mode test runners (Vitest/Playwright) download a prebuilt
    # Chromium that expects an FHS filesystem and cannot start here. This one
    # runs natively; the harness picks it up off PATH.
    ungoogled-chromium
    uv
  ];
}
