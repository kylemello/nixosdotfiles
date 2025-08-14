{ pkgs, ... }:

{
  home.packages = with pkgs; [
    cargo
    deno
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
