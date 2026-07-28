{ lib, config, pkgs, ... }:

# Canonical layout, identical on every machine. Anything host-specific — in
# particular artemis's symlinks into the Windows filesystem — lives in
# home/wsl.nix, so these directories only ever contain real files and the
# sync layers never have to reason about cross-platform symlinks.
#
# ~/notes and ~/scratch are the two roots home/sync.nix syncs; ~/personal and
# ~/work are the two kyle.wip.roots. All four are created here so a fresh
# machine has them before either layer runs.
let
  # The work identity, as a store file rather than an inline heredoc. A
  # heredoc's `>` redirect is performed by the SHELL, so $DRY_RUN_CMD (which is
  # `echo` under `home-manager switch --dry-run`) does not gate it: a dry run
  # would truncate and rewrite ~/work/.gitconfig with the literal word `cat`.
  # `$DRY_RUN_CMD install …` has no redirect, so a dry run really is dry.
  workGitconfig = pkgs.writeText "work-gitconfig" ''
    [user]
      email = kmello@broadriverrehab.com
  '';
in
{
  home.activation.createDirsAndFiles = lib.hm.dag.entryAfter ["writeBoundary"] ''
    $DRY_RUN_CMD mkdir -p "$HOME/personal"
    $DRY_RUN_CMD mkdir -p "$HOME/work"
    $DRY_RUN_CMD mkdir -p "$HOME/notes"
    $DRY_RUN_CMD mkdir -p "$HOME/scratch"
    # Absolute path, not bare `install`: BSD install (macOS) has no -D, and the
    # activation script's PATH is not guaranteed to put GNU coreutils first.
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -Dm644 ${workGitconfig} "$HOME/work/.gitconfig"
  '';
}
