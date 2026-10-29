{ lib, pkgs, ... }:

# `tpane` — a Bubble Tea TUI for reordering, swapping, breaking out and joining
# tmux panes and windows. Source in home/tpane/; opened with prefix + P.
#
# Imported by home/tmux.nix rather than by each profile: it is only useful
# where tmux is, so it goes wherever tmux goes. Not in home/tmux-common.nix
# because psmux on artemis's Windows side cannot run a Linux binary.
let
  inherit (import ./tmux-common.nix) catppuccin;

  version = "0.1.0";

  tpane = pkgs.buildGoModule {
    pname = "tpane";
    inherit version;
    src = ./tpane;
    # Changes whenever go.mod/go.sum or the set of imported packages does: set
    # it to lib.fakeHash, build, and copy the real hash out of the error.
    vendorHash = "sha256-r5P+xnYRrmxqVqkYTRw+Tz2OIMSrla4grYUlgTPHCXo=";
    ldflags = [ "-s" "-w" "-X main.version=${version}" ];
    meta.mainProgram = "tpane";
  };
in
{
  home.packages = [ tpane ];

  # -EE: close only on a clean exit, so a startup error stays readable.
  programs.tmux.extraConfig = ''
    bind P display-popup -EE -w 85% -h 80% -b rounded -S "fg=${catppuccin.blue}" -T " tpane " ${lib.getExe tpane}
  '';
}
