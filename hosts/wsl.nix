{ config, pkgs, lib, ... }:

{
  # Enable core WSL integration.
  wsl = {
    enable = true;
    defaultUser = "kyle";
  };
}
