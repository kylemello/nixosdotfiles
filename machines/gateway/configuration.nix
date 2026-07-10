{ config, pkgs, ... }:

let
  # Login banner: the colorful "GATEWAY" ANSI art (machines/gateway/banner.ans)
  # followed by a dynamic "Welcome to <host>, <user>" line. Built once as a tiny
  # command so both bash (/etc/profile) and fish login shells can just run it.
  loginBanner = pkgs.writeShellScriptBin "gateway-login-banner" ''
    # Only draw the banner on a real terminal (skip scp/sftp/piped logins).
    [ -t 1 ] || exit 0
    cat ${./banner.ans}
    # Greet with the account's first name: take the GECOS field
    # (`users.users.<n>.description`, passwd field 5), drop any comma-part, then
    # keep only the first whitespace-separated word. Fall back to the username.
    user="$(${pkgs.coreutils}/bin/id -un)"
    name="$(${pkgs.getent}/bin/getent passwd "$user" | ${pkgs.coreutils}/bin/cut -d: -f5 | ${pkgs.coreutils}/bin/cut -d, -f1 | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
    [ -n "$name" ] || name="$user"
    printf '\n\033[1;36mWelcome to %s, %s\033[0m\n\n' "${config.networking.hostName}" "$name"
  '';
in
{
  imports = [
    ./hardware-configuration.nix
    ../../hosts/common.nix
  ];

  # Machine-specific settings
  networking.hostName = "gateway";

  nixpkgs.config.allowUnfree = true;

  services.qemuGuest.enable = true;

  # Show the login banner for both bash (/etc/profile) and fish login shells.
  environment.systemPackages = [ loginBanner ];
  environment.loginShellInit = "${loginBanner}/bin/gateway-login-banner";
  programs.fish.loginShellInit = "${loginBanner}/bin/gateway-login-banner";

  # --- Accounts -------------------------------------------------------------

  # Kyle (owner). Base account/groups come from hosts/common.nix; just the key.
  users.users.kyle = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGHjWpYtbVkI+N6NbmnVYvI+YBnpRlnPjaYNFqhNTMqE"
    ];
  };

  # Seth — friend who may need occasional access. No sudo (not in wheel),
  # bash shell (familiar), SSH-key-only login.
  #   - `ci` group      -> read/write the runner workspace under /home/ci
  #   - `systemd-journal`-> `journalctl -u github-runner-gateway` without sudo
  # (He can also start/stop/restart the runner via the scoped sudo rule below.)
  users.users.seth = {
    isNormalUser = true;
    description = "Seth Hemphill";
    shell = pkgs.bash;
    extraGroups = [ "ci" "systemd-journal" ];
    openssh.authorizedKeys.keys = [
      # TODO: paste Seth's SSH public key here so he can log in, e.g.
      # "ssh-ed25519 AAAA...  seth@his-laptop"
    ];
  };

  # Dedicated service account for the CI runner. No sudo; in `docker` so
  # workflows can build/run containers. Not a login target (no SSH keys).
  # homeMode 0750 lets the `ci` group (i.e. seth) traverse/read the home,
  # where the runner workspace lives.
  users.groups.ci = {};
  users.users.ci = {
    isNormalUser = true;
    description = "CI runner service account";
    shell = pkgs.bash;
    group = "ci";
    extraGroups = [ "docker" ];
    homeMode = "0750";
  };

  # Runner workspace inside ci's home. setgid (2770) so files the runner
  # creates are group-owned by `ci`, letting seth read/write build artifacts.
  # The runner wipes this dir's *contents* on every start (not the rest of home).
  systemd.tmpfiles.rules = [
    "d /home/ci/actions-runner 2770 ci ci -"
  ];

  # Let Seth manage just the runner service — no full sudo. Exact commands only.
  security.sudo.extraRules = [
    {
      users = [ "seth" ];
      commands = [
        { command = "/run/current-system/sw/bin/systemctl start github-runner-gateway.service"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/systemctl stop github-runner-gateway.service"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/systemctl restart github-runner-gateway.service"; options = [ "NOPASSWD" ]; }
      ];
    }
  ];

  # --- CI: self-hosted GitHub Actions runner --------------------------------
  # Runs as the `ci` user above. To turn on:
  #   1. set `url` to your repo (https://github.com/OWNER/REPO) or org
  #      (https://github.com/ORG).
  #   2. create the token file, readable only by root, NOT committed to git:
  #        sudo install -Dm600 /dev/stdin /var/lib/ci-runner/github-token
  #        (paste a runner registration token or a PAT with repo / admin:org)
  #   3. flip `enable` below to true and rebuild.
  services.github-runners.gateway = {
    enable = false;
    name = "gateway";
    url = "https://github.com/OWNER/REPO"; # TODO: set real repo/org URL
    tokenFile = "/var/lib/ci-runner/github-token";
    user = "ci";
    group = "ci";
    workDir = "/home/ci/actions-runner";
    extraLabels = [ "gateway" "nixos" ];
    extraPackages = with pkgs; [ git docker ];

    # The runner is sandboxed with ProtectHome=true by default, which masks all
    # of /home — so a workDir under /home/ci is unreachable without this. Turning
    # it off is REQUIRED for the home-based workDir, but note the tradeoff: CI
    # jobs can now see other users' home dirs (/home/kyle, /home/seth). If that
    # matters more than the home-based workspace, move workDir to
    # /var/lib/ci-runner/work instead and drop this override.
    serviceOverrides.ProtectHome = false;
  };

  # Assign the Home Manager profile to the user
  home-manager.users.kyle = import ../../users/kyle/home.nix;

  system.stateVersion = "25.05";
}
