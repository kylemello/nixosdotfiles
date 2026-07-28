{ config, pkgs, lib, ... }:

{
  # Home Manager refuses to replace a pre-existing unmanaged file and fails the
  # WHOLE rebuild rather than skipping it ("Existing file ... would be
  # clobbered", check-link-targets.sh). home/claude.nix is about to take over
  # ~/.claude/{settings.json,settings.local.json,skills}, all three of which
  # already exist here by hand — note an empty directory counts, so `skills`
  # collides too. Without this, `nixos-rebuild switch --flake .#artemis` aborts.
  #
  # This lives in hosts/wsl.nix, NOT hosts/common.nix, because artemis is the
  # only NixOS host with any Home-Manager-managed dotfile collisions:
  # kyle.claude.enable is off on atlas/gateway/nixosvm, and setting the option
  # in hosts/common.nix perturbs all four systemd home-manager units (measured:
  # it changes atlas/gateway/nixosvm's system derivation hashes for no benefit).
  #
  # The backups are one-shot: a second rebuild fails if a `.hm-bak` from the
  # first is still sitting there, so clear them once the switch is confirmed.
  home-manager.backupFileExtension = "hm-bak";

  # Enable core WSL integration.
  wsl = {
    enable = true;
    docker-desktop.enable = true;
    defaultUser = "kyle";
    useWindowsDriver = true;
    interop.includePath = false;
  };

  # ---- SSH into the WSL instance ------------------------------------------
  # WSL runs with `networkingMode=mirrored` (set Windows-side in
  # %USERPROFILE%\.wslconfig), so the distro shares the host's network
  # interfaces instead of sitting behind a NAT. Two consequences:
  #
  #   * Windows' own OpenSSH server already listens on :22, and in mirrored
  #     mode the host wins that port — so sshd here must use a different one
  #     or it silently never receives a connection.
  #   * Binding 0.0.0.0 is enough to be reachable at the host's LAN and
  #     Tailscale addresses; no `netsh interface portproxy` forwarding needed
  #     (that is only required for the default NAT mode).
  #
  # Windows still gates inbound traffic to the WSL vSwitch behind the Hyper-V
  # firewall, which defaults to DefaultInboundAction=Block. Opening the port
  # below is necessary but NOT sufficient — the host-side rules are imperative
  # and live outside Nix. To (re)apply them, in an elevated PowerShell:
  #
  #   New-NetFirewallHyperVRule -Name WSL-SSH -DisplayName 'WSL SSH' `
  #     -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' `
  #     -Protocol TCP -LocalPorts 2222 -Action Allow
  #   New-NetFirewallRule -DisplayName 'WSL SSH' -Direction Inbound `
  #     -Protocol TCP -LocalPort 2222 -Action Allow -Profile Private,Domain
  services.openssh = {
    enable = true;
    ports = [ 2222 ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  networking.firewall.allowedTCPPorts = [ 2222 ];

  services.pulseaudio.enable = true;
  networking.wireless.enable = lib.mkForce false;

  nixpkgs.config.allowUnfree = true;

  environment.unixODBCDrivers = [ pkgs.unixodbcDrivers.msodbcsql18 ];
}
