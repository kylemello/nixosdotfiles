{ config, pkgs, lib, ... }:

{
  # Enable core WSL integration.
  wsl = {
    enable = true;
    docker-desktop.enable = true;
    defaultUser = "kyle";
    useWindowsDriver = true;
    interop.includePath = false;
  };

  services.openssh.enable = false;
  networking.wireless.enable = lib.mkForce false;

  nixpkgs.config.allowUnfree = true;

  environment.unixODBCDrivers = [ pkgs.unixodbcDrivers.msodbcsql18 ];
}
