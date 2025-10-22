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

  services.openvpn.servers = {
    jamsitVPN = { config = ''
      config /home/kyle/openvpn/jamsitVPN.ovpn
      auth-user-pass /home/kyle/openvpn/credentials.txt
    ''; };
  };

  nixpkgs.config.allowUnfree = true;

  environment.unixODBCDrivers = [ pkgs.unixODBCDrivers.msodbcsql18 ];
}
