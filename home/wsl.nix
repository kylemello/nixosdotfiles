{ config, pkgs, ... }:

{
  # Alias common SSH commands to their Windows executable counterparts.
  # This is crucial for interoperability with Windows-based SSH agents.
  home.shellAliases = {
    ssh = "ssh.exe";
    scp = "scp.exe";
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
