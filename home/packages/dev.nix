{ pkgs, ... }:

{
  home.packages = with pkgs; [
    air # Live reload for golang
    cargo
    deno
    doppler
    gcc
    gh
    go
    jdk
    lazydocker
    lazygit
    nodePackages."@angular/cli"
    nodejs
    pnpm
    python3
    rustc
    tree-sitter
    uv
  ];
}
