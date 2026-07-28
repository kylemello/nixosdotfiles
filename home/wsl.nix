{ config, pkgs, ... }:

{
  # Alias common SSH commands to their Windows executable counterparts.
  # This is crucial for interoperability with Windows-based SSH agents.
  home.shellAliases = {
    ssh = "ssh.exe";
    scp = "scp.exe";
    explorer = "/mnt/c/WINDOWS/explorer.exe";
    rsync="rsync -e \"ssh.exe\"";
  };

  programs.command-not-found.enable = true;

  home = {
    sessionPath = [
      # Specific Paths we need since we're not adding host paths
      "/mnt/c/WINDOWS/System32/OpenSSH/"
      "/mnt/c/Program Files/OpenSSH/"
      "/mnt/c/Users/kylem/AppData/Local/Programs/Microsoft VS Code/bin/code"
      "/mnt/c/Users/kylem/AppData/Local/Programs/Zed/bin/"
    ];
  };

  # Configure Git to use the Windows SSH client.
  programs.git = {
    settings = {
      # This tells Git to use the Windows SSH executable for all its operations,
      # which is necessary for it to communicate with agents running on the host.
      core = {
        sshCommand = "ssh.exe";
      };

      # This configures Git to use the 1Password SSH agent on Windows for signing commits.
      # The path points directly to the executable on the Windows filesystem.
      gpg = {
        # ssh.program = "/mnt/c/Users/kylem/AppData/Local/1Password/app/8/op-ssh-sign.exe"; # Stable branch Windows 1Password
        ssh.program = "/mnt/c/Users/kylem/AppData/Local/Microsoft/WindowsApps/op-ssh-sign.exe"; # Nightly branch
      };
    };
  };

  # Logical host name for `wip` refs. See home/wip.nix. Enabled HERE and not in
  # users/kyle/home.nix, which all four NixOS hosts import.
  kyle.wip = {
    enable = true;
    host = "artemis";
    roots = [ "personal" "work" ];
    # The Windows-side 1Password agent serves this host's keys; Nix's openssh
    # cannot reach it. Without this every wip push fails auth silently.
    #
    # This bare name resolves ONLY through home.sessionPath above
    # (hosts/wsl.nix sets wsl.interop.includePath = false), which nothing
    # non-interactive sources — so home/wip.nix appends home.sessionPath to the
    # wrapper's own PATH. Keep that in place or the systemd timer silently
    # resolves nothing. If ssh.exe ever moves out of the two OpenSSH
    # directories listed above, add the new one there.
    sshCommand = "ssh.exe";
  };
}
