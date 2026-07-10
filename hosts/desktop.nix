{ config, lib, pkgs, ... }:

{
  fonts.packages = with pkgs; [
    nerd-fonts.meslo-lg
  ];
  # Enable the GNOME Desktop Environment.
  services = {
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "kyle" ];
  };

  # Unlock the GNOME keyring from your password at the gdm login screen.
  # (`services.gnome.gnome-keyring.enable` in hosts/common.nix wires this up for
  # the console `login` PAM service but not for gdm, so graphical logins would
  # otherwise leave the keyring locked and libsecret clients would prompt.)
  security.pam.services.gdm-password.enableGnomeKeyring = true;
}
