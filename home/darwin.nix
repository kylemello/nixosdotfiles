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
  # participate do.
  #
  # sshCommand and identityFile are both left at their defaults: Nix's openssh,
  # and ~/.ssh/wip_hub_ed25519. The hub is deliberately NOT reached through this
  # machine's 1Password agent — see kyle.wip.identityFile in home/wip.nix. Note
  # ~/.ssh/config sets `IdentityAgent` under `Host *` here, which is exactly why
  # the hub options include IdentitiesOnly=yes.
  #
  # This host cannot reach the hub until ~/.ssh/wip_hub_ed25519 exists here and
  # its public half is in machines/gateway/configuration.nix.
  kyle.wip = {
    enable = true;
    host = "ariane";
    roots = [ "personal" "work" ];
  };

  # Warn at shell start when ariane is running an older nixosdotfiles than the
  # checkout, or than artemis has already pushed. Enabled here, not in a shared
  # profile — see home/drift.nix. Relies on kyle.wip.driftCheck (default true)
  # to keep `@{u}` fresh.
  kyle.drift.enable = true;

  # Shared shell history through the gateway hub, behind fzf.fish's Ctrl-R.
  # Enabled here, not in a shared profile — see home/atuin.nix.
  kyle.atuin.enable = true;

  # ~/.claude symlinked out of this repo and shared with artemis. Enabled here,
  # not in a shared profile — see home/claude.nix.
  kyle.claude = {
    enable = true;
    host = "ariane";
  };

  # ~/notes and ~/scratch through the gateway Syncthing hub. Enabled here, not
  # in a shared profile — see home/sync.nix.
  kyle.sync = {
    enable = true;
    host = "ariane";
  };
}
