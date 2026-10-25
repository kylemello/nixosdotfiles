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
    codex
    deno
    devenv
    docker-buildx
    dolt
    # Plain `dotnet-sdk` is still pinned to 8.0 LTS in nixpkgs, so name the
    # version. ariane already had this for Azure Storage Explorer and keeps the
    # DOTNET_ROOT wiring it needs in home/darwin.nix.
    dotnetCorePackages.sdk_10_0
    emacs-nox
    gcc
    gh
    git-cliff
    gitleaks
    glab
    gnumake
    go
    google-cloud-sdk
    infisical
    infracost
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
    # devenv bundles its own bin/secretspec (2.2.1 ships 0.17.1), so the two
    # collide in home-manager's buildEnv. hiPrio makes nixpkgs' newer standalone
    # build win the symlink; devenv still uses its bundled copy internally.
    (lib.hiPrio secretspec)
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
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (with pkgs; [
    ungoogled-chromium
  ]);
}
