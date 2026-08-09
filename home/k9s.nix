{ ... }:

# k9s, declared through `programs.k9s` rather than as a bare package entry in
# home/packages/base.nix.
#
# This is load-bearing for theming, not a style preference. catppuccin/nix's
# k9s port (modules/home-manager/k9s.nix) gates its whole `config` block on:
#
#   config.catppuccin.enable && cfg.enable && config.programs.k9s.enable
#
# With k9s arriving as a plain `home.packages` entry that last conjunct is
# false, so despite catppuccin.autoEnable being on, the port wrote no skin and
# never set `ui.skin` — k9s fell back to its built-in colours. Moving k9s here
# satisfies the guard; the port then drops catppuccin-mocha.yaml into the skins
# directory and points `ui.skin` at it.
#
# Where the files land is handled by both modules in the same way: on Darwin
# with `xdg.enable = false` (our case on ariane) they go to
# ~/Library/Application Support/k9s, which is where k9s actually looks on
# macOS; everywhere else, $XDG_CONFIG_HOME/k9s.
#
# `programs.k9s.package` defaults to pkgs.k9s, so this still installs the
# binary — that is why base.nix no longer lists it.
{
  programs.k9s.enable = true;
}
