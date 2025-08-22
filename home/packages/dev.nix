{ pkgs, ... }:

{
  home.packages = with pkgs; [
    air # Live reload for golang
    cargo
    deno
    doppler
    gcc
    gh
    gnumake
    go
    jdk
    lazydocker
    lazygit
    nodePackages."@angular/cli"
    nodejs
    pkg-config
    pnpm
    python3
    ruby
    rustc
    tree-sitter
    uv
  ];
}
