{ pkgs, ... }:

{
  home.packages = with pkgs; [
    bootdev-cli
    dive
    fastfetch
    gemini-cli
    upterm
    yazi
    yt-dlp
  ];
}
