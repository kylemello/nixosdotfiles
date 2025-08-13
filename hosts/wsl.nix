{ config, pkgs, lib, ... }:

{
  # Enable core WSL integration.
  wsl = {
    enable = true;
    defaultUser = "kyle";
  };
  users.mutableUsers = lib.mkForce true;
}
