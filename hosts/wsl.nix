{ config, pkgs, ... }:

{
  # Enable core WSL integration.
  wsl = {
    enable = true;
    defaultUser = "kyle";
  };
}
