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
    ];
  };

  # Configure Git to use the Windows SSH client.
  programs.git = {
    extraConfig = {
      # This tells Git to use the Windows SSH executable for all its operations,
      # which is necessary for it to communicate with agents running on the host.
      core = {
        sshCommand = "ssh.exe";
      };

      # This configures Git to use the 1Password SSH agent on Windows for signing commits.
      # The path points directly to the executable on the Windows filesystem.
      gpg = {
        ssh.program = "/mnt/c/Users/kylem/AppData/Local/1Password/app/8/op-ssh-sign.exe";
      };
    };
  };
}
