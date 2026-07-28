{ config, lib, pkgs, ... }:

{
  # macOS-specific user tweaks — the analogue of home/wsl.nix.
  #
  # programs.git (home/git.nix) sets signByDefault with an SSH signing key, so
  # every commit is signed. On macOS we sign through the 1Password app's
  # op-ssh-sign helper (mirroring the WSL setup, which points at
  # op-ssh-sign.exe). Without this, signing would fall back to ssh-keygen and
  # fail unless the private key were on disk.
  programs.git.settings.gpg.ssh.program =
    "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";

  # Land in fish inside tmux. NixOS hosts make fish the login shell
  # (users.defaultUserShell in hosts/common.nix), so tmux inherits it there.
  # Standalone Home Manager on macOS can't set a login shell, so it stays zsh
  # and tmux would otherwise spawn zsh in every window/pane. Force fish per
  # pane. (For non-tmux terminals, set fish as your login shell with `chsh`.)
  programs.tmux.extraConfig = lib.mkAfter ''
    set -g default-command "${pkgs.fish}/bin/fish"
  '';

  # Logical host name for `wip` refs — NOT the machine's real hostname
  # (kyles-macbook-pro), which would make for confusing ref names. Enabled here
  # rather than in a shared profile, so only the machines that should
  # participate do. sshCommand is left at its pkgs.openssh default: macOS
  # 1Password exposes its agent through a local socket that Nix's ssh reaches.
  kyle.wip = {
    enable = true;
    host = "ariane";
    roots = [ "personal" "work" ];
  };
}
