{ config, lib, pkgs, ... }:

# Omarchy — an Arch-based, opinionated Hyprland desktop. Standalone Home
# Manager; there is no NixOS module and no nix-darwin here, so this is the
# analogue of home/wsl.nix (artemis) and home/darwin.nix (ariane).
#
# The split of responsibilities, and why this layer reads as a list of things
# deliberately NOT taken:
#
#   Omarchy owns the DESKTOP and the LOOK. It is not a bare distro with a
#   package manager bolted on — it ships Hyprland, waybar, the terminals, the
#   browsers, 1Password, docker and a whole theme system (`omarchy-theme-set`,
#   ~/.config/omarchy/themes) that rewrites ~/.config for the apps it themes. It
#   also ships its own LazyVim tree and its own Claude Code skills.
#
#   Nix owns the TOOLCHAIN and the shared dotfiles. Everything in
#   home/packages/{base,dev,misc}.nix, fish, git, tmux, k9s — the parts that
#   should be identical to artemis and ariane.
#
# Where the two would write the same file, Omarchy wins and Nix stays out of the
# way. That is a real constraint, not politeness: Home Manager refuses to clobber
# an unmanaged path ("existing file is in the way"), and for the paths it *would*
# win, `omarchy-theme-set` would overwrite them on the next theme switch and the
# machine would silently drift from its own config.
#
# The pacman duplicates are accepted on purpose. As of 2026-08-26 pacman and Nix
# both provide neovim, bat, eza, fd, fzf, ripgrep, zoxide, jq, gnupg, lazygit,
# lazydocker, fastfetch, nodejs, docker and tmux. Nix's copies win on PATH, so
# tool behaviour matches the other machines; pacman's stay because Omarchy's own
# scripts call them and several are hard dependencies of its meta-packages.
# Removing them to save a couple of GB would trade a working desktop for disk
# this machine has 349 GB of.
{
  imports = [
    # The SSH host aliases and 1Password agent wiring, without the rest of
    # home/profiles/desktop.nix — see the ghostty note in home/ssh.nix. This
    # machine has no ~/.ssh at all yet, so this is the whole client config.
    ./ssh.nix
  ];

  # --- Theming: hand off to Omarchy -----------------------------------------
  #
  # home/catppuccin.nix sets catppuccin.autoEnable = true, which enrolls EVERY
  # supported program. That is right on artemis and ariane and wrong here: the
  # ports write into ~/.config for btop, ghostty, alacritty and friends, all of
  # which Omarchy generates from the active theme. The failure is not loud —
  # activation either aborts on "file in the way", or succeeds and gets undone
  # the next time the theme changes.
  #
  # So: opt out globally and re-enable the single port whose file nothing else
  # claims. Note this is NOT a loss of theming — Omarchy's own theme is applied
  # to those apps, and fish/tmux are themed by home/fish.nix's catppuccin-fish
  # plugin and home/tmux.nix's inline mocha palette, neither of which goes
  # through this module.
  catppuccin.autoEnable = lib.mkForce false;

  # home/k9s.nix HARD-depends on this: the port's config block is gated on
  # `catppuccin.enable && catppuccin.k9s.enable && programs.k9s.enable`, and
  # that module's whole reason for existing is to satisfy the third conjunct.
  # ~/.config/k9s is unclaimed by Omarchy, so this one is safe.
  catppuccin.k9s.enable = true;

  # --- Git ------------------------------------------------------------------
  #
  # home/git.nix sets gpg.format = ssh and signByDefault, but names no signing
  # program, so each machine layer points it at its own 1Password. Here that is
  # pacman's, at a fixed FHS path — NOT `pkgs._1password-gui` the way
  # home/profiles/desktop.nix does it, which would pull a second copy of the
  # whole GUI app into the store to use one helper binary out of it.
  #
  # NOTE the 1Password SSH agent is not switched on yet on this machine
  # (~/.1password/agent.sock does not exist), so signing will fail until it is:
  #   1Password -> Settings -> Developer -> Use the SSH agent.
  programs.git.settings.gpg.ssh.program = "/opt/1Password/op-ssh-sign";

  # Omarchy ships its own ~/.config/git/config, which Home Manager cannot merge
  # with — it renders that file whole. Rather than lose its contents, the parts
  # that are not already in home/git.nix are restated here. Everything below is
  # transcribed from the Omarchy default (which is moved aside to
  # config.omarchy.bak by the activation step at the bottom of this file); its
  # [user] and [init] blocks are dropped as duplicates of home/git.nix.
  #
  # These are all generically good settings, not Omarchy-specific ones. If they
  # earn their keep here they should be promoted into home/git.nix so artemis and
  # ariane get them too — kept local for now so this machine's first switch
  # changes nothing about the other two.
  programs.git.settings = {
    alias = {
      co = "checkout";
      br = "branch";
      ci = "commit";
      st = "status";
    };

    pull.rebase = true; # Rebase (instead of merge) on pull
    push.autoSetupRemote = true; # Automatically set upstream branch on push
    diff = {
      algorithm = "histogram"; # Clearer diffs on moved/edited lines
      colorMoved = "plain"; # Highlight moved blocks in diffs
      mnemonicPrefix = true; # More intuitive refs in diff output
    };
    commit.verbose = true; # Include diff in the commit message template
    column.ui = "auto"; # Output in columns when possible
    branch.sort = "-committerdate"; # Most recent commit first
    tag.sort = "-version:refname"; # Sort version numbers as you would expect
    rerere = {
      enabled = true; # Record and reuse conflict resolutions
      autoupdate = true; # Apply stored resolutions automatically
    };
  };

  # --- Shell ----------------------------------------------------------------
  #
  # Land in fish inside tmux, exactly as home/darwin.nix does and for the same
  # reason: standalone Home Manager cannot set the login shell (/etc/shells and
  # /etc/passwd are root's), so tmux would otherwise spawn whatever the account's
  # shell is in every window and pane. Kept even though fish IS the login shell
  # here, so tmux is right on a machine where the one-time chsh has not been run.
  programs.tmux.extraConfig = lib.mkAfter ''
    set -g default-command "${pkgs.fish}/bin/fish"
  '';

  # Fish as the LOGIN shell. Two one-time steps as root, because chsh refuses a
  # shell that is not in /etc/shells and standalone Home Manager can write
  # neither file:
  #
  #   echo "$HOME/.nix-profile/bin/fish" | sudo tee -a /etc/shells
  #   sudo chsh -s "$HOME/.nix-profile/bin/fish" "$USER"
  #
  # Both name the ~/.nix-profile symlink rather than a store path, for the reason
  # home/darwin.nix gives: the store path changes on every fish bump and would
  # eventually be garbage-collected, and for a LOGIN shell that means an account
  # that cannot open a terminal. ~/.nix-profile is a GC root that Home Manager
  # repoints on each switch.

  # Fish does NOT read /etc/profile, and that is load-bearing on this machine in
  # two directions:
  #
  #   1. /etc/profile.d/nix.sh is what puts ~/.nix-profile/bin on PATH for bash.
  #      A fish login shell never sources it, so without the sessionPath below
  #      NOTHING Nix installs would be on PATH — including fish itself, which is
  #      what the login shell resolves to. mkBefore puts these ahead of
  #      home/fish.nix's entries so the Nix profile wins over ~/.local/bin, where
  #      Omarchy keeps mise wrapper scripts for some of the same tools.
  #
  #   2. /etc/profile.d/omarchy.sh is what sets OMARCHY_PATH and appends
  #      ~/.local/share/mise/shims + ~/.local/bin. Nothing is needed here for the
  #      DESKTOP case: /usr/share/uwsm/env.d/10-omarchy sources the same
  #      env-bootstrap into the Hyprland session, so a terminal launched from
  #      Hyprland inherits OMARCHY_PATH and those entries already (verified with
  #      `systemctl --user show-environment`). An `ssh omarchy` straight into fish
  #      does not get them; that is the accepted gap.
  home.sessionPath = lib.mkBefore [
    "$HOME/.nix-profile/bin"
    "/nix/var/nix/profiles/default/bin"
  ];

  # Omarchy's shell layer is bash-only — ~/.bashrc sources
  # $OMARCHY_PATH/default/bash/{envs,shell,aliases,functions,init}, none of which
  # fish can read. Making fish the login shell would silently drop all of it, so
  # the aliases and functions are ported here. Transcribed from
  # /usr/share/omarchy/default/bash/aliases as of 2026-08-26.
  #
  # Four deliberate omissions:
  #   cd    — home/fish.nix already aliases it to `z`. Omarchy's `zd` wrapper adds
  #           a "print the directory it jumped to" flourish on top of the same
  #           zoxide; not worth diverging from the other two machines for.
  #   ff    — its kitty-vs-other branch keys off $TERM, and the fzf preview is
  #           already covered by fzf.fish's Ctrl-T binding from home/fish.nix.
  #   eff   — depends on ff.
  #   mup   — `mise up`, and this machine has just handed mise's overlapping
  #           tools to Nix. `nix flake update` is the equivalent now.
  programs.fish.shellAliases = {
    # File system. `ls` is deliberately shadowed, matching Omarchy's own default;
    # home/fish.nix's l/ll/llr stay alongside it.
    ls = "eza -lh --group-directories-first --icons=auto";
    lsa = "eza -lh --group-directories-first --icons=auto -a";
    lt = "eza --tree --level=2 --long --icons --git";
    lta = "eza --tree --level=2 --long --icons --git -a";

    # Directories
    ".." = "cd ..";
    "..." = "cd ../..";
    "...." = "cd ../../..";

    # Tools
    a = "omarchy-agent --inline";
    c = "opencode --auto";
    cy = "codex --approve-for-me";
    d = "docker";
    r = "rails";
    t = "tmux attach || tmux new -s Work";
    h = "herdr";
    ic = "tdl c";
    ix = "tdl cx";
    icx = "tdl c cx";

    # Git
    g = "git";
    gcm = "git commit -m";
    gcam = "git commit -a -m";
    gcad = "git commit -a --amend";
  };

  programs.fish.functions = {
    # `cx` is a function rather than an alias only because of the escape
    # sequence: fish's alias builtin would need the same quoting anyway, and a
    # function keeps the printf readable. Clears scrollback, then launches Claude.
    cx = {
      description = "Clear the screen and launch Claude Code in auto mode";
      body = ''
        printf "\033[2J\033[3J\033[H"
        claude --permission-mode auto $argv
      '';
    };

    # nvim, defaulting to the current directory. Omarchy's version uses `command
    # nvim` to step past its own function of the same name; in fish the function
    # does not shadow the binary unless it is named `nvim`, but `command` is kept
    # so the intent survives a future rename.
    n = {
      description = "Open nvim, defaulting to the current directory";
      body = ''
        if test (count $argv) -eq 0
            command nvim .
        else
            command nvim $argv
        end
      '';
    };

    # Copy the most recently modified file, chosen interactively, to a remote.
    sff = {
      description = "scp a recently-modified file, picked with fzf, to a destination";
      body = ''
        if test (count $argv) -eq 0
            echo "Usage: sff <destination> (e.g. sff host:/tmp/)" >&2
            return 1
        end
        set -l file (find . -type f -printf '%T@\t%p\n' \
            | sort -rn | cut -f2- \
            | fzf --preview 'bat --style=numbers --color=always {}')
        test -n "$file"; and scp "$file" $argv[1]
      '';
    };

    # xdg-open, detached and silenced. Named `open` to match Omarchy; on Linux
    # there is no system `open` for it to shadow.
    open = {
      description = "xdg-open in the background, output discarded";
      body = ''
        xdg-open $argv >/dev/null 2>&1 &
        disown
      '';
    };
  };

  # --- Claude Code ----------------------------------------------------------
  #
  # The MCP servers and the home-directory trust flag, WITHOUT the ~/.claude
  # symlinks — see kyle.claudeCode.enable in home/claude-code.nix for why the
  # two had to be split. In short: ~/.claude/skills here holds Omarchy's own
  # `omarchy` and `diagnose-crash` skills, which are not in this repo and which
  # the symlink would hide.
  #
  # home-assistant still needs its token added by hand (see that module), and
  # atlassian-aegis still needs one interactive /mcp authenticate.
  kyle.claudeCode.enable = true;

  # home/wip.nix and home/sync.nix are not even imported — see the note in
  # users/kyle/omarchy.nix. Of what IS imported, these stay off, each for a
  # specific reason rather than by oversight:
  #
  #   kyle.claude    — would replace ~/.claude/{skills,settings.json,CLAUDE.md}
  #                    with this repo's. Omarchy's two skills live in there and
  #                    are not in the repo. Turning this on means first deciding
  #                    whether those skills move into claude/skills/ (this repo
  #                    is PUBLIC) and adding a claude/local/omarchy.json.
  #   kyle.nvim      — ~/.config/nvim here is Omarchy's LazyVim, carrying four
  #                    specs this repo does not have (all-themes,
  #                    omarchy-theme-hotreload, disable-news-alert,
  #                    snacks-animated-scrolling-off) plus its own options.lua
  #                    and theme.lua. The theme hot-reload one is what keeps nvim
  #                    in step with `omarchy-theme-set`; the symlink would take
  #                    all four away.
  #   kyle.opencode  — ~/.config/opencode/opencode.json already exists here, and
  #                    that module points opencode at the ollama server that only
  #                    artemis runs.

  # Shared shell history with artemis and ariane, behind fzf.fish's Ctrl-R. Unlike
  # kyle.wip this needs no SSH key at all — atuin syncs over plain HTTP to
  # sync_address (http://gateway:8888), and that host resolves and answers from
  # here already (gateway.lan.kmello.dev, 10.11.12.105, verified 2026-08-26).
  #
  # One manual step remains, and until it is done auto_sync will log an auth
  # failure every 5 minutes (see the option description in home/atuin.nix).
  # Atuin end-to-end encrypts, so the key has to come off a machine that already
  # has it rather than being re-derived:
  #
  #   atuin key                      # on artemis or ariane, to read it out
  #   atuin login -u <user> -k <key> # here, once
  #
  # Local recording works from the first shell either way; login is what makes
  # the other two machines' history show up.
  kyle.atuin.enable = true;

  # The half of the drift alarm that matters needs no hub at all: it compares the
  # repo's HEAD against the stamp written at the last activation, so it still
  # says "you have pulled but not switched". The "behind the other machine" half
  # would need kyle.wip.driftCheck's fetch timer, which this machine does not
  # import, so that branch compares against an @{u} nothing advances and stays
  # quiet. That is the intended behaviour here, not a gap.
  kyle.drift.enable = true;

  # --- Making room for Home Manager ----------------------------------------
  #
  # Home Manager aborts rather than overwrite a file it does not manage, which
  # is the right default and also means a first switch on a machine that already
  # has these files fails halfway. Move them aside once, idempotently, BEFORE
  # the file-linking phase.
  #
  # entryBefore "checkLinkTargets" is the load-bearing detail: that is the step
  # that raises "existing file is in the way", so anything running after it is
  # too late. Each move is a no-op on every subsequent activation because the
  # source is by then a symlink into the store, which `-f … -L` skips.
  home.activation.omarchyStashUnmanaged =
    lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      stash() {
        # $1 is the path; skip when it is missing, or already ours (a symlink
        # into /nix/store), so this only ever fires on the real pre-Nix file.
        if [ -e "$1" ] && [ ! -L "$1" ]; then
          echo "omarchy: moving unmanaged $1 aside to $1.omarchy.bak"
          $DRY_RUN_CMD mv "$1" "$1.omarchy.bak"
        fi
      }
      stash "$HOME/.config/git/config"
      stash "$HOME/.config/tmux/tmux.conf"
    '';
}
