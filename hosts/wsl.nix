{ config, pkgs, lib, ... }:

{
  # Enable core WSL integration.
  wsl = {
    enable = true;
    defaultUser = "kyle";
    useWindowsDriver = true;
  };

  services.openssh.enable = false;

  nixpkgs.config.allowUnfree = true;

  services.xserver.videoDrivers = ["nvidia"];
}
