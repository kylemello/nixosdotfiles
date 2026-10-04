{ config, lib, ... }:

# Keep Codex's editable configuration in the checkout, like home/claude.nix.
let
  cfg = config.kyle.codex;
  repo = "${config.home.homeDirectory}/nixosdotfiles/codex";
in
{
  options.kyle.codex.enable = lib.mkEnableOption ''
    ~/.codex/config.toml symlinked out of the nixosdotfiles checkout.
    Enable only on hosts that have the checkout at ~/nixosdotfiles.
  '';

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.pathExists ../codex/config.toml;
        message = "kyle.codex.enable is on but codex/config.toml is missing from the flake.";
      }
    ];

    # Auth, sessions, plugins and other runtime state remain in ~/.codex.
    home.file.".codex/config.toml".source =
      config.lib.file.mkOutOfStoreSymlink "${repo}/config.toml";
  };
}
