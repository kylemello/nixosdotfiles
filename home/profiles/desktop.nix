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
    enable = true;
    extraConfig = ''
      # ================
      # General Settings
      # ================
      Include ~/.ssh/1Password/config

      # For 1password-cli
      Host *
        ForwardAgent yes
        IdentitiesOnly yes
        IdentityAgent "~/.1password/agent.sock"

      # =======================
      # Friend Hosts
      # =======================
      Host cdbits
        HostName cdbits.xyz
        User kmello
        Port 2520

      # =======================
      # Home Hosts
      # =======================
      Host atlas
        HostName 10.11.12.104
        User kyle

      Host newatlas
        HostName 172.19.1.21
        User kyle

      Host sputnik
        HostName 10.11.12.5
        User root

      Host artemis
        HostName 10.11.12.102
        User kylem

      Host ariane
        HostName ariane
        User kyle

      Host github.com
        HostName github.com
        User git

      Host gitea.kmello.dev
        HostName gitea.kmello.dev
        Port 2222
        User git

      Host opnsense
        HostName 10.11.12.1
        User kly108

      # =======================
      # Broad River Rehab Hosts
      # =======================

      Host mercury
        HostName brrit.com
        User kyle

      Host iodine
        HostName 10.20.23.241
        User kmello

      Host gl.brrapps.io
        HostName gl.brrapps.io
        User git
        # Port 522

      Host uranium
        HostName 10.20.23.230
        User kmello

      Host polonium
        HostName 10.20.23.232
        User kmello

      Host plutonium
        HostName brr.docresolve.com
        User kyle

      Host lead
        HostName 10.20.23.240
        User root

      Host vega
        HostName 10.20.23.254
        user jamsit-sa

      Host nitrogen
        HostName 10.20.23.243
        user kmello

      Host mageai
        HostName mage-iitzd-u20494.vm.elestio.app
        User root

      Host strontium
        HostName dev.brrit.com
        User kyle
    '';
  };
}
