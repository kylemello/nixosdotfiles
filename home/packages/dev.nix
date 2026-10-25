{ pkgs, lib, ... }:

{
  home.packages = (with pkgs; [
    _1password-cli
    air # Live reload for golang
    ansible
    awscli2
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
    # nixpkgs marks python3Packages.fabric broken, so Hydra never builds
    # azure-cli and every update compiles it from source along with ~15
    # azure-mgmt-* packages: about 5 minutes, the slowest part of an ariane
    # switch. ariane installs Homebrew's prebuilt bottle instead
    # (`brew install azure-cli`, Microsoft's recommended macOS install);
    # artemis keeps building it through overlays/fabric.nix. Move it back to
    # the main list once fabric is unbroken and azure-cli is cached again.
    azure-cli
    ungoogled-chromium
  ]);
}
