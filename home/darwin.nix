{ config, lib, pkgs, ... }:

let
  # See home.packages below. The SDK is a superset of the runtime Storage
  # Explorer actually needs; swap in dotnetCorePackages.runtime_10_0 to drop
  # the `dotnet` CLI and most of the closure.
  dotnet = pkgs.dotnetCorePackages.sdk_10_0;
  dotnetRoot = "${dotnet}/share/dotnet";
in
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

    # OFF because the tick's `git -C ~/nixosdotfiles fetch` goes to GitHub over
    # SSH, which reaches the 1Password agent and asks for approval every five
    # minutes. The dedicated hub key fixed the wip<->gateway path; this is a
    # separate one, and the key cannot help because the flake remote is
    # git@github.com and must stay on the interactive credential.
    #
    # Only the `@{u}` half of the drift alarm depended on this. The half that
    # matters -- "you have commits this machine has not switched to" -- compares
    # local HEAD against the last-activation stamp and still works.
    driftCheck = false;
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

  # .NET 10, for Microsoft Azure Storage Explorer. Here rather than in the
  # shared home/packages/dev.nix because only this machine runs that app, and
  # the SDK is a 1.3GB closure the Linux hosts have no use for.
  #
  # Storage Explorer 1.45 ships a ServiceHub host under
  # Contents/Resources/app/ServiceHub/Hosts/microsoft-servicehub-host whose
  # runtimeconfig.json asks for Microsoft.NETCore.App 10.0.0. With no runtime
  # present it dies with "You must install .NET to run this application".
  home.packages = [ dotnet ];

  # For shells. Note this does NOT help Storage Explorer: that apphost never
  # consults PATH, and a Finder-launched GUI inherits launchd's environment
  # rather than fish's. It probes DOTNET_ROOT_ARM64, then DOTNET_ROOT, then
  # /etc/dotnet/install_location_arm64, then /usr/local/share/dotnet.
  home.sessionVariables.DOTNET_ROOT = dotnetRoot;

  # ...so the GUI is pointed at .NET through /etc/dotnet, which standalone Home
  # Manager (no nix-darwin here) cannot write. One-time, as root:
  #
  #   sudo mkdir -p /etc/dotnet
  #   echo "$HOME/.local/share/dotnet" | sudo tee /etc/dotnet/install_location_arm64
  #
  # That file names the symlink below and not a store path directly, because
  # the store path changes on every dotnet bump and /etc would rot into a
  # garbage-collected path. Home Manager repoints the symlink on each switch.
  #
  # Not ~/.dotnet: that is dotnet's own user-install/tools directory, and
  # handing it a read-only store symlink would break `dotnet tool install`.
  home.file.".local/share/dotnet".source = dotnetRoot;
}
