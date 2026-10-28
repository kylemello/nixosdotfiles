{ config, lib, pkgs, ... }:

let
  # Must stay the same derivation home/packages/dev.nix installs, so the
  # DOTNET_ROOT below and the `dotnet` on PATH cannot drift apart.
  dotnet = pkgs.dotnetCorePackages.sdk_10_0;
  dotnetRoot = "${dotnet}/share/dotnet";

  # Symbolic hotkey 263 is Keyboard Shortcuts > Screenshots > "Ask Siri about
  # active window" (⇧⌘Space: keycode 49, modifiers 0x120000). The value is
  # written back out with the default binding so Settings still shows it, just
  # unchecked. The live WindowServer state is read and set through SkyLight's
  # CGS*SymbolicHotKey* calls from JXA, so no python or compiled helper.
  hotkeysPlist =
    "${config.home.homeDirectory}/Library/Preferences/com.apple.symbolichotkeys.plist";
  noSiriWindowShortcut = pkgs.writeShellScript "no-siri-window-shortcut" ''
    set -euo pipefail
    live=$(/usr/bin/osascript -l JavaScript -e '
      ObjC.import("CoreGraphics");
      ObjC.bindFunction("CGSIsSymbolicHotKeyEnabled", ["bool", ["int"]]);
      $.CGSIsSymbolicHotKeyEnabled(263)')
    saved=$(/usr/bin/defaults export com.apple.symbolichotkeys - \
      | /usr/bin/plutil -extract AppleSymbolicHotKeys.263.enabled raw -o - - 2>/dev/null || true)
    [ "$live" = false ] && [ "$saved" = false ] && exit 0
    /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 263 \
      '<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1179648</integer></array><key>type</key><string>standard</string></dict></dict>'
    /usr/bin/osascript -l JavaScript -e '
      ObjC.import("CoreGraphics");
      ObjC.bindFunction("CGSSetSymbolicHotKeyEnabled", ["int", ["int", "bool"]]);
      $.CGSSetSymbolicHotKeyEnabled(263, false)' >/dev/null
    echo "$(date '+%F %T') re-disabled hotkey 263 (live: $live, saved: ''${saved:-unset})"
  '';
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
  # Standalone Home Manager on macOS has no equivalent — the login shell lives
  # in Open Directory, not in any file this profile can write — so tmux would
  # otherwise spawn the account's zsh in every window/pane. Force fish per pane.
  #
  # Kept even now that the login shell below is fish: it makes tmux land in
  # fish on a machine where the one-time chsh has not been run yet.
  programs.tmux.extraConfig = lib.mkAfter ''
    set -g default-command "${pkgs.fish}/bin/fish"
  '';

  # Fish as the *login* shell, for terminals that aren't tmux. Two one-time
  # steps as root, because `chsh` refuses a shell that isn't in /etc/shells and
  # neither file is writable from standalone Home Manager:
  #
  #   echo "$HOME/.nix-profile/bin/fish" | sudo tee -a /etc/shells
  #   sudo chsh -s "$HOME/.nix-profile/bin/fish" "$USER"
  #
  # Both name the profile symlink rather than a store path, for the same reason
  # /etc/dotnet does below: the store path changes on every fish bump and would
  # eventually be garbage-collected, which for a *login shell* means an account
  # that cannot open a terminal. ~/.nix-profile is a GC root and Home Manager
  # repoints it on each switch.
  #
  # Verify with `dscl . -read /Users/$USER UserShell`.

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
    # Personal login everywhere, the work one under ~/work.
    workAccount.enable = true;
  };

  # ~/.config/nvim symlinked out of this repo and shared with artemis. Enabled
  # here, not in a shared profile — see home/nvim.nix.
  kyle.nvim.enable = true;

  # ~/notes and ~/scratch through the gateway Syncthing hub. Enabled here, not
  # in a shared profile — see home/sync.nix.
  kyle.sync = {
    enable = true;
    host = "ariane";
  };

  # The SDK itself comes from the shared home/packages/dev.nix; what follows is
  # the extra wiring Microsoft Azure Storage Explorer needs, which only this
  # machine runs. Storage Explorer 1.45 ships a ServiceHub host under
  # Contents/Resources/app/ServiceHub/Hosts/microsoft-servicehub-host whose
  # runtimeconfig.json asks for Microsoft.NETCore.App 10.0.0. With no runtime
  # present it dies with "You must install .NET to run this application".

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

  # macOS 27's Siri AI keeps turning "Ask Siri about active window" back on
  # after it is unchecked in Settings, stealing ⇧⌘Space. Sometimes it rewrites
  # the plist, and sometimes it re-enables the hotkey live in WindowServer with
  # the plist still saying off (2026-10-27), which no file watch can see. So
  # re-disable it whenever the plist changes, at login, and every 30s. The
  # script is a no-op when both are already off, so its own write retriggering
  # the watch is harmless; launchd's default 10s throttle bounds any tug-of-war.
  launchd.agents.no-siri-window-shortcut = {
    enable = true;
    config = {
      ProgramArguments = [ "${noSiriWindowShortcut}" ];
      WatchPaths = [ hotkeysPlist ];
      StartInterval = 30;
      RunAtLoad = true;
      ProcessType = "Background";
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/no-siri-window-shortcut.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/no-siri-window-shortcut.log";
    };
  };
}
