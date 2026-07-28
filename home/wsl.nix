{ config, pkgs, ... }:

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
  # directories on every machine; nothing above is recreated declaratively.

  # Logical host name for `wip` refs. See home/wip.nix. Enabled HERE and not in
  # users/kyle/home.nix, which all four NixOS hosts import.
  kyle.wip = {
    enable = true;
    host = "artemis";
    roots = [ "personal" "work" ];
    # The Windows-side 1Password agent serves this host's keys; Nix's openssh
    # cannot reach it. Without this every wip push fails auth silently.
    #
    # This bare name resolves ONLY through home.sessionPath above
    # (hosts/wsl.nix sets wsl.interop.includePath = false), which nothing
    # non-interactive sources — so home/wip.nix appends home.sessionPath to the
    # wrapper's own PATH. Keep that in place or the systemd timer silently
    # resolves nothing. If ssh.exe ever moves out of the two OpenSSH
    # directories listed above, add the new one there.
    sshCommand = "ssh.exe";
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
}
