{ pkgs, ... }:

{
  home.packages = with pkgs; [
    bootdev-cli
    claude-code
    dive
    fastfetch
    gemini-cli
    postgresql_18
    unixODBC
    unixODBCDrivers.msodbcsql18
    upterm
    yazi
    yt-dlp
  ];
}
