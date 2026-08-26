{ config, lib, pkgs, ... }:

let
  # C:\Users\kylem\.ssh\config — the file every ssh.exe on this box already
  # reads. Hardcoded the same way as the sessionPath entries and op-ssh-sign
  # below: this module only ever evaluates on artemis.
  windowsSshConfig = "/mnt/c/Users/kylem/.ssh/config";
in
{
  # Alias common SSH commands to their Windows executable counterparts.
  # This is crucial for interoperability with Windows-based SSH agents.
  home.shellAliases = {
    ssh = "ssh.exe";
    scp = "scp.exe";
    explorer = "/mnt/c/WINDOWS/explorer.exe";
    rsync="rsync -e \"ssh.exe\"";
  };

  programs.command-not-found.enable = true;

  home = {
    sessionPath = [
      # Specific Paths we need since we're not adding host paths
      "/mnt/c/WINDOWS/System32/OpenSSH/"
      "/mnt/c/Program Files/OpenSSH/"
      "/mnt/c/Users/kylem/AppData/Local/Programs/Microsoft VS Code/bin/code"
      "/mnt/c/Users/kylem/AppData/Local/Programs/Zed/bin/"
    ];
  };

  # Configure Git to use the Windows SSH client.
  programs.git = {
    settings = {
      # This tells Git to use the Windows SSH executable for all its operations,
      # which is necessary for it to communicate with agents running on the host.
      core = {
        sshCommand = "ssh.exe";
      };

      # This configures Git to use the 1Password SSH agent on Windows for signing commits.
      # The path points directly to the executable on the Windows filesystem.
      gpg = {
        # ssh.program = "/mnt/c/Users/kylem/AppData/Local/1Password/app/8/op-ssh-sign.exe"; # Stable branch Windows 1Password
        ssh.program = "/mnt/c/Users/kylem/AppData/Local/Microsoft/WindowsApps/op-ssh-sign.exe"; # Nightly branch
      };
    };
  };

  # ~/.ssh/config IS the Windows one. Everything on this host that matters
  # already reaches ssh through `ssh.exe` — the aliases above, and git via
  # core.sshCommand — and ssh.exe reads C:\Users\kylem\.ssh\config natively,
  # so the Windows file is the single source of truth for host aliases. This
  # points Nix's openssh at that same file, so `command ssh`, ansible, rsync
  # and anything else that bypasses the alias resolve the same host names.
  #
  # mkOutOfStoreSymlink, not a store copy: the file is edited on the Windows
  # side and has to take effect there without a rebuild here.
  #
  # Only `config`, never the whole ~/.ssh directory. wip's hub key
  # (~/.ssh/wip_hub_ed25519, see kyle.wip below) has to stay on the ext4 side:
  # a private key under /mnt/c inherits drvfs's 0777 and OpenSSH refuses to
  # load it at all.
  #
  # The Windows file's first line is `Include ~/.ssh/1Password/config`, which
  # from here resolves to /home/kyle/.ssh/1Password/config and does not exist.
  # OpenSSH ignores an Include matching nothing, so this is harmless (verified
  # 2026-08-25) — it does mean Nix's ssh gets no 1Password keys, which it does
  # not need: that agent lives on the Windows side and only ssh.exe reaches it.
  home.file.".ssh/config".source =
    config.lib.file.mkOutOfStoreSymlink windowsSshConfig;

  # OpenSSH fatals on a group- or world-writable user config:
  #
  #   Bad owner or permissions on /home/kyle/.ssh/config
  #
  # and drvfs hands out 0777, which is exactly that — so without this chmod
  # the symlink above breaks EVERY Nix-side ssh on the host, wip's hub sync
  # included. /mnt/c is mounted with `metadata` (/etc/wsl.conf), so the mode
  # sticks in an NTFS extended attribute; Windows and ssh.exe never consult
  # POSIX modes, so nothing on that side notices. Verified 2026-08-25.
  #
  # The attribute is lost if a Windows editor replaces the file instead of
  # writing it in place (save-to-temp-then-rename). That failure is loud, and
  # this re-applies on every activation, so the fix is a rebuild — or a plain
  # `chmod go-w` from WSL.
  home.activation.windowsSshConfigPerms =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ -e ${lib.escapeShellArg windowsSshConfig} ]; then
        $DRY_RUN_CMD chmod go-w ${lib.escapeShellArg windowsSshConfig}
      else
        echo "wsl: ${windowsSshConfig} is missing — ~/.ssh/config will dangle" >&2
      fi
    '';

  # Paths backed by the Windows filesystem. These exist on artemis only; they
  # cannot cross to macOS, and they must never enter a sync root.
  #
  # Already present on disk (created by hand, left as-is):
  #   ~/.aws                  -> /mnt/c/Users/kylem/.aws
  #   ~/.azure                -> /mnt/c/Users/kylem/.azure
  #   ~/.docker/contexts      -> /mnt/c/Users/kylem/.docker/contexts
  #   ~/.docker/features.json -> /mnt/c/Users/kylem/.docker/features.json
  #
  # ~/work/work-knowledge-repo -> /mnt/c/Users/kylem/Vaults/work-knowledge-repo
  # is a git repo living INSIDE a sync root, on the 9p filesystem. `wip_repos`
  # uses plain `find` (no -L), which does not traverse symlinks, so it is
  # skipped. Do not add -L to that find without excluding this path first.
  #
  # home/folders.nix creates ~/personal ~/work ~/notes ~/scratch as real
  # directories on every machine; nothing in the list above is recreated
  # declaratively. ~/.ssh/config, just above, is the one that IS.

  # Logical host name for `wip` refs. See home/wip.nix. Enabled HERE and not in
  # users/kyle/home.nix, which all four NixOS hosts import.
  kyle.wip = {
    enable = true;
    host = "artemis";
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

    # sshCommand is deliberately LEFT AT ITS DEFAULT (Nix's openssh) even though
    # everything else on this host reaches ssh through `ssh.exe` and the
    # Windows-side 1Password agent. It used to be `sshCommand = "ssh.exe"`;
    # do not put that back. Three reasons, in order of weight:
    #
    # 1. Windows OpenSSH implements no ControlMaster. Multiplexing is what turns
    #    a tick's ~36 SSH authentications into one, and it is simply unavailable
    #    through ssh.exe — so on this host the fix is impossible without moving
    #    off it.
    # 2. The hub is now reached with a dedicated on-disk key
    #    (kyle.wip.identityFile, ~/.ssh/wip_hub_ed25519), which the agent is not
    #    involved in at all. Machine-to-machine sync should not authenticate
    #    with a credential designed to prompt a human for approval.
    # 3. Nix's ssh resolves `gateway` here perfectly well (10.11.12.105, via the
    #    lan.kmello.dev search domain — verified 2026-07-28), and wip_hub_up
    #    passes StrictHostKeyChecking=accept-new, so it seeds its own
    #    known_hosts entry on the first tick before any git operation runs.
    #
    # GitHub is unaffected: programs.git.settings.core.sshCommand above still
    # points git at ssh.exe, and home/wip.nix's drift fetch reads that same
    # setting rather than kyle.wip.sshCommand.
    #
    # This host cannot reach the hub until ~/.ssh/wip_hub_ed25519 exists here
    # and its public half is in machines/gateway/configuration.nix.
  };

  # Warn at shell start when artemis is running an older nixosdotfiles than the
  # checkout, or than ariane has already pushed. Enabled HERE for the same
  # reason kyle.wip is: users/kyle/home.nix reaches all four NixOS hosts, and
  # atlas/gateway/nixosvm have no second machine to drift from. Relies on
  # kyle.wip.driftCheck (on by default above) to keep `@{u}` fresh.
  kyle.drift.enable = true;

  # Shared shell history through the gateway hub, behind fzf.fish's Ctrl-R.
  # Enabled HERE, not in users/kyle/home.nix, for the same reason as the two
  # above — see home/atuin.nix.
  kyle.atuin.enable = true;

  # ~/.claude symlinked out of this repo and shared with ariane. Enabled HERE
  # for the same reason as the three above, plus one specific to it: the
  # symlinks point at ~/nixosdotfiles, which only artemis and ariane have
  # checked out — on atlas/gateway/nixosvm they would dangle.
  kyle.claude = {
    enable = true;
    host = "artemis";
  };

  # ~/.config/nvim symlinked out of this repo and shared with ariane. Enabled
  # HERE for the same checkout reason as kyle.claude — see home/nvim.nix.
  kyle.nvim.enable = true;

  # ~/notes and ~/scratch through the gateway Syncthing hub. Enabled HERE and
  # never in users/kyle/home.nix — that profile reaches gateway, which already
  # runs the hub itself. See home/sync.nix for what that mistake does.
  kyle.sync = {
    enable = true;
    host = "artemis";
  };

  # ~/.config/opencode/opencode.json pointing opencode at the ollama server in
  # hosts/wsl.nix. Enabled HERE for the same reason as everything above, plus a
  # specific one: artemis is the only machine with the GPU and the server, so
  # the provider would be dead config anywhere else.
  kyle.opencode.enable = true;

  # ~/docker-composes, the hand-run dev stacks (postgres, mysql, dolt, redis,
  # open-webui). Enabled HERE because artemis is the only host with Docker
  # Desktop's WSL integration — and the open-webui stack points at the ollama
  # server hosts/wsl.nix runs on this machine.
  kyle.dockerComposes.enable = true;
}
