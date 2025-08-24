{ lib, pkgs, ... }:

{
  home.packages = with pkgs; [
    ghostty
  ];

  programs.git = {
    extraConfig = {
      "gpg \"ssh\"" = {
        program = "${lib.getExe' pkgs._1password-gui "op-ssh-sign"}";
      };
    };
  };

  programs.ssh = {
    extraConfig = ''
      Include ~/.ssh/1Password/config 

      Host *
        IdentityAgent "~/.1password/agent.sock"
    '';
  };
}
