{ config, lib, pkgs, ... }:

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
# satisfies the guard.
#
# `programs.k9s.package` defaults to pkgs.k9s, so this still installs the
# binary — that is why base.nix no longer lists it.
let
  # Mocha, mirroring the local palette in home/tmux.nix. Only the entries used
  # below are listed; add more as needed rather than pasting the whole ramp.
  mocha = {
    pink = "#f5c2e7";
    red = "#f38ba8";
    peach = "#fab387";
    yellow = "#f9e2af";
    green = "#a6e3a1";
    teal = "#94e2d5";
    sapphire = "#74c7ec";
    blue = "#89b4fa";
    text = "#cdd6f4";
    surface0 = "#313244";
  };

  flavor = config.catppuccin.k9s.flavor;
  baseSkin = "${config.catppuccin.sources.k9s}/catppuccin-${flavor}.yaml";

  # The catppuccin port's skin is CURRENT with upstream catppuccin/k9s (verified
  # byte-identical against dist/catppuccin-mocha.yaml) — but upstream itself only
  # covers 67 of the 86 keys k9s 0.51 can skin. Every key it leaves out falls
  # back to a hardcoded default in k9s' internal/config/styles.go, and those
  # defaults are raw named colours: `aqua`, `lawngreen`, `lightskyblue`,
  # `mediumvioletred`, `orange`. That is why the theme reads as almost-right —
  # `info.cpuColor` (lawngreen) and `info.k9sRevColor` (aqua) sit in the header
  # panel that is on screen at all times.
  #
  # Each mapping below keeps the default's SEMANTICS, not its hue: error stays
  # red, warn goes to yellow, cpu stays green. Comments record what k9s would
  # otherwise use, so a future k9s bump can be diffed against them.
  #
  # Two of the nineteen are deliberately left alone:
  #   frame.menu.fgStyle        — a TextStyle (bold/italic), not a colour.
  #   views.charts.resourceColors — a map whose key names are constants defined
  #                                 outside styles.go; not worth guessing.
  gapFill = (pkgs.formats.yaml { }).generate "k9s-catppuccin-gapfill.yaml" {
    k9s = {
      body = {
        logoColorError = mocha.red; # was "red"
        logoColorWarn = mocha.yellow; # was "mediumvioletred"
        logoColorInfo = mocha.green; # was "green"
        logoColorMsg = mocha.text; # was "white"
      };
      prompt.border = {
        command = mocha.blue; # was "aqua"
        default = mocha.green; # was "seagreen"
      };
      info = {
        cpuColor = mocha.green; # was "lawngreen"
        memColor = mocha.sapphire; # was "darkturquoise"
        k9sRevColor = mocha.teal; # was "aqua"
      };
      views = {
        table.header.selectedSortColumnColor = mocha.pink; # was "lightskyblue"
        picker = {
          mainColor = mocha.text; # was "white"
          focusColor = mocha.blue; # was "aqua"
          shortcutColor = mocha.peach; # was "aqua"
        };
        charts = {
          focusFgColor = mocha.text; # was "white"
          focusBgColor = mocha.surface0; # was "orange"
          defaultChartColors = [ mocha.green mocha.red ]; # was palegreen/orangered
          defaultDialColors = [ mocha.green mocha.red ]; # was palegreen/orangered
        };
      };
    };
  };

  # k9s reads exactly ONE skin file and does not merge them, so the gap-fill has
  # to be baked into a copy of the port's skin rather than layered beside it.
  # Deep merge, gap-fill winning; the port's own file stays untouched in
  # skins/ (unused) so an upstream fix to it is still visible in a diff.
  completeSkin = pkgs.runCommand "catppuccin-${flavor}-complete.yaml" { } ''
    ${pkgs.yq-go}/bin/yq eval-all 'select(fi == 0) * select(fi == 1)' \
      ${baseSkin} ${gapFill} > $out
  '';

  skinName = "catppuccin-${flavor}-complete";
in
{
  # The palette above is mocha's. Fail loudly rather than silently pairing
  # mocha hexes with, say, latte's base if the flavour is ever switched.
  assertions = [{
    assertion = flavor == "mocha";
    message = ''
      home/k9s.nix hardcodes the Catppuccin *mocha* palette for the keys
      upstream's k9s skin leaves unset, but catppuccin.k9s.flavor is
      "${flavor}". Update `mocha` in that file to the new flavour's ramp.
    '';
  }];

  programs.k9s = {
    enable = true;
    skins.${skinName} = completeSkin;
    # mkForce: the catppuccin port sets this to the bare "catppuccin-${flavor}",
    # which is the 67-key file this one extends.
    settings.k9s.ui.skin = lib.mkForce skinName;
  };
}
