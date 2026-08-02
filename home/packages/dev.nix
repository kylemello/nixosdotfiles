{ pkgs, lib, ... }:

{
  home.packages = (with pkgs; [
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
    # secretspec is intentionally not listed: devenv ships its own
    # bin/secretspec, and two copies collide in home-manager's buildEnv.
    sqlc # was a `go install` into ~/go/bin on artemis only
    sqlite
    tea
    terraform
    tokei
    tree-sitter
    uv
  ])
  # Browser-mode test runners (Vitest/Playwright) download a prebuilt Chromium
  # that expects an FHS filesystem and cannot start on the Linux hosts. This
  # one runs natively; the harness picks it up off PATH. Linux-only both
  # because that is the problem it solves — a Mac runs the downloaded build
  # fine — and because nixpkgs' chromium has no darwin platform at all, which
  # otherwise fails the ariane eval outright.
  ++ lib.optionals pkgs.stdenv.isLinux (with pkgs; [
    ungoogled-chromium
  ]);
}
