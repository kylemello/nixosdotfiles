{lib, pkgs}: {
  home-manager = {
    home.shellAliases = {
      ssh = "ssh.exe";
      scp = "scp.exe";
    };

    programs.git = {
      extraConfig = {
        core = {
          sshCommand = "ssh.exe";
        };

        gpg = {
          ssh.program = "/mnt/c/Users/kylem/AppData/Local/1Password/app/8/op-ssh-sign.exe";
        };
      };
    };
  };

  nixos = {
    wsl = {
      enable = true;
      defaultUser = "kyle";
    };

    environment.systemPackages = [
      pkgs.keychain
    ];
  };
}
