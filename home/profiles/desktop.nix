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
      Host *
        IdentityAgent "~/.1password/agent.sock"
    '';
  };
}
