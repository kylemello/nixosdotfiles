{ config, lib, pkgs, ... }:

# Neovim's *editable* config (~/.config/nvim), shared between artemis and ariane
# through this repo. The tree in nvim/ is the LazyVim starter as it stood on
# artemis, copied verbatim (minus the starter's README.md) — lua/config/* plus
# the five personal specs in lua/plugins/ (catppuccin, flash, which-key, the
# treesitter community fork, Fastfile=ruby).
#
# The neovim BINARY is not installed here: home/packages/base.nix already puts
# neovim-unwrapped on every host, config or no config. Everything LazyVim shells
# out to is likewise already in the shared package sets — git, ripgrep, fd,
# gcc, nodejs_24, unzip, lazygit, tree-sitter — so a fresh machine has them
# before nvim first runs.
let
  cfg = config.kyle.nvim;
in
{
  options.kyle.nvim.enable = lib.mkEnableOption ''
    ~/.config/nvim symlinked out of this repo.

    Off by default and enabled per-host in home/wsl.nix and home/darwin.nix,
    NOT in users/kyle/home.nix — that profile is imported by all four NixOS
    hosts, and atlas/gateway/nixosvm have no ~/nixosdotfiles checkout to point
    the symlink at, so enabling it there would produce a dangling link. They
    still get plain neovim from home/packages/base.nix
  '';

  config = lib.mkIf cfg.enable (
    let
      # Point at the live working copy, NOT the nix store, exactly as
      # home/claude.nix does. This has to be writable: lazy.nvim rewrites
      # lazy-lock.json on every :Lazy update/sync, and :LazyExtras rewrites
      # lazyvim.json. Under a read-only store path both fail — so the config
      # would be declarative in name and broken in practice.
      #
      # The upside of it being the working copy: those two files land in git as
      # ordinary diffs, so `git pull` + `:Lazy restore` puts the other machine
      # on the same plugin revisions.
      repo = "${config.home.homeDirectory}/nixosdotfiles/nvim";
    in
    {
      # Flakes only see git-tracked files, and a forgotten `git add nvim/` would
      # otherwise show up as an empty-looking config on the *other* machine
      # rather than as a build error here.
      assertions = [
        {
          assertion = builtins.pathExists ../nvim/init.lua;
          message = "kyle.nvim.enable is on but nvim/init.lua is not in the flake "
            + "(did you forget to `git add nvim/`?).";
        }
      ];

      # One symlink for the whole directory rather than a file-by-file mapping:
      # lazy.nvim and LazyVim both create files in here (lazy-lock.json,
      # lazyvim.json), and anything not explicitly listed would land inside a
      # read-only store directory and fail.
      #
      # Plugins themselves are NOT managed: lazy.nvim clones them into
      # ~/.local/share/nvim/lazy, which stays machine-local state.
      #
      # NOTE the first activation on a machine that already has a real
      # ~/.config/nvim directory fails with "existing file is in the way" —
      # Home Manager will not clobber unmanaged paths. Move it aside once:
      #   mv ~/.config/nvim ~/.config/nvim.pre-nix
      home.file.".config/nvim".source = config.lib.file.mkOutOfStoreSymlink repo;
    }
  );
}
