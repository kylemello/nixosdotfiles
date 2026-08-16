{ pkgs, lib, ... }:

{
  home.packages = (with pkgs; [
    bootdev-cli
    claude-code
    dive
    fastfetch
    ffmpeg
    ncdu
    postgresql_18
    tesseract
    typst
    upterm
    unrar
    yazi
    yt-dlp
  ])
  # The Microsoft SQL Server ODBC driver (msodbcsql18) is Linux-only in
  # nixpkgs, so keep it (and unixODBC alongside it) off non-Linux hosts such as
  # the ariane Mac.
  ++ lib.optionals pkgs.stdenv.isLinux (with pkgs; [
    unixodbc
    unixodbcDrivers.msodbcsql18
  ]);
}
