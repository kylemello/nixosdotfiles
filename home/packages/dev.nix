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
    # withMailutils only buys emacs `movemail`, and mailutils 3.21 no longer
    # links on aarch64-darwin: libmu_sieve's uidnew extension leaves
    # mu_url_{set_scheme,sget_path,to_string} undefined, which the macOS linker
    # rejects outright where ELF would have let it slide.
    #
    #   ld: symbol(s) not found for architecture arm64
    #
    # Not an overlay, because that would rebuild emacs on the Linux hosts too,
    # where mailutils is fine and cached. Revisit when nixpkgs' mailutils
    # builds on darwin again.
    (if stdenv.hostPlatform.isDarwin then emacs-nox.override { withMailutils = false; } else emacs-nox)
    gcc
    gh
    gitleaks
    glab
    gnumake
    go
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
