{ config, lib, pkgs, ... }:

# Warn at shell start when this machine is running an older nixosdotfiles than
# the checkout on disk, or than the other machine has already pushed. The whole
# point of the two-machine sync is that config changes made on one machine show
# up on the other; nothing else notices when they have not been applied.
let
  cfg = config.kyle.drift;

  repo = "${config.home.homeDirectory}/nixosdotfiles";

  # Shares home/wip.nix's state directory deliberately: the fetch that keeps
  # `@{u}` fresh is done by that module's timer (kyle.wip.driftCheck), so the
  # two are operationally one feature. Resolved from config.xdg.stateHome, the
  # same way home/wip.nix resolves its own, rather than hardcoding
  # ~/.local/state — see the WIP_CACHE comment there.
  stamp = "${config.xdg.stateHome}/wip/last-switch";

  # Writer and reader apply the SAME rule for "is this a usable commit id".
  # Anything else — a zero-byte file from a failed write, the literal command
  # text a dry run would leave behind — is reported as a broken stamp rather
  # than silently read as "you have drifted", which is the difference between
  # an alarm you act on and one you learn to ignore.
  shaRe = "^[0-9a-f]{40}$";
in
{
  options.kyle.drift.enable = lib.mkEnableOption ''
    a shell-start warning when nixosdotfiles has moved since the last switch.

    Off by default and enabled per-host in home/wsl.nix and home/darwin.nix,
    NOT in users/kyle/home.nix — that profile is imported by all four NixOS
    hosts, and atlas/gateway/nixosvm must stay byte-identical to a tree
    without this module.

    Assumes kyle.wip.driftCheck is on for the same user: that timer is what
    fetches the flake repo, and without it the "behind the other machine"
    branch compares against an `@{u}` that never advances and stays quiet
  '';

  config = lib.mkIf cfg.enable {
    # Record the commit that was actually activated. The check below compares
    # it against the repo's current HEAD plus whatever the timer has fetched.
    #
    # Written only on success, and never through a shell redirect. `git … >
    # "${stamp}"` truncates the file before git runs and is covered by neither
    # `2>/dev/null` nor `|| true`, so any git hiccup — dubious ownership, an
    # unborn HEAD, a mid-rebase tree — leaves a zero-byte stamp; and under
    # --dry-run $DRY_RUN_CMD is `echo`, so the redirect would write the literal
    # command text. Either way the warning below then fires on every single
    # shell and re-running ./update.sh does not clear it.
    #
    # Every failure path says something. The activation script runs under
    # `set -eu -o pipefail`, so these are guarded rather than left to abort a
    # whole home-manager switch over a diagnostic file — but a stamp that
    # cannot be written is exactly the state that makes the alarm useless, so
    # it is never swallowed.
    home.activation.recordFlakeRev = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # -e, not -d: in a git worktree or submodule `.git` is a file.
      if [ ! -e ${lib.escapeShellArg repo}/.git ]; then
        echo "drift: ${repo}/.git is missing — the shell-start drift check will stay silent" >&2
      # 2>&1 so a git failure lands IN $rev and can be quoted back to the user.
      elif rev="$(${pkgs.git}/bin/git -C ${lib.escapeShellArg repo} rev-parse HEAD 2>&1)" \
           && [[ "$rev" =~ ${shaRe} ]]; then
        # An explicit dry-run branch rather than the usual `$DRY_RUN_CMD cmd`
        # prefix, because the prefix cannot gate a `>` redirect — the shell
        # performs the redirect before it ever looks at the command, which is
        # the whole defect being fixed here.
        #
        # `install -m600 /dev/stdin` was tried first and does NOT work: GNU
        # coreutils install stats the source, copies, re-stats, and bails with
        # "skipping file '/dev/stdin', as it was replaced while being copied",
        # writing nothing. Hence temp-file-then-rename, which also makes the
        # publish atomic — a shell starting mid-activation reads either the old
        # stamp or the new one, never a half-written one.
        if [ -n "''${DRY_RUN_CMD:-}" ]; then
          echo "drift: dry run — would record $rev in ${stamp}"
        elif ! { ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg (builtins.dirOf stamp)} \
                 && printf '%s\n' "$rev" > ${lib.escapeShellArg "${stamp}.new"} \
                 && ${pkgs.coreutils}/bin/chmod 600 ${lib.escapeShellArg "${stamp}.new"} \
                 && ${pkgs.coreutils}/bin/mv -f ${lib.escapeShellArg "${stamp}.new"} ${lib.escapeShellArg stamp}; }; then
          ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg "${stamp}.new"}
          echo "drift: could not write ${stamp} — the shell-start check will report a broken stamp until this succeeds" >&2
        fi
      else
        echo "drift: could not read HEAD in ${repo}, leaving ${stamp} as it was. git said: $rev" >&2
      fi
    '';

    # Warn at shell start. At most two `git` forks and no network — home/wip.nix's
    # timer already did the fetch, so `@{u}` is at most one tick stale.
    #
    # `read` rather than `cat` because it is a fish builtin: this runs in every
    # interactive shell and every new tmux pane, so the forks are counted.
    # Measured on ariane 2026-07-28, 40 shell starts: +33 ms in the up-to-date
    # case (both forks), +2 ms when the stamp is unusable (neither). That is the
    # honest price of reading git state. It could be cut by parsing
    # .git/HEAD and .git/refs/... directly, but those go missing the moment git
    # packs its refs, and a drift alarm that quietly stops firing is worse than
    # a slower one.
    #
    # The second branch asks `rev-list --count` directly instead of comparing
    # HEAD to `@{u}`. Those two differ whenever the local branch is AHEAD as
    # well — unpushed commits — and the brief's version would then announce
    # "nixosdotfiles is 0 commit(s) behind the other machine". Counting and
    # requiring > 0 says nothing in that case, which is correct: being ahead is
    # not drift, and `git pull` is not the fix for it.
    programs.fish.interactiveShellInit = lib.mkAfter ''
      if test -e ${repo}/.git; and test -f ${stamp}
          set -l switched ""
          read -l switched < ${stamp}
          if not string match -qr '${shaRe}' -- "$switched"
              set_color yellow
              echo "⚠  nixosdotfiles: drift stamp unreadable — re-run ./update.sh to reset it"
              set_color normal
          else
              set -l current (git -C ${repo} rev-parse HEAD 2>/dev/null)
              if test -z "$current"
                  # Nothing to compare against; the activation warning above
                  # already covered why, and repeating it every shell would not
                  # add anything.
              else if test "$switched" != "$current"
                  set_color yellow
                  echo "⚠  nixosdotfiles moved since your last switch — run ./update.sh"
                  set_color normal
              else
                  set -l behind (git -C ${repo} rev-list --count HEAD..'@{u}' 2>/dev/null)
                  if test -n "$behind"; and test "$behind" -gt 0
                      set_color yellow
                      echo "⚠  nixosdotfiles is $behind commit(s) behind the other machine — git pull && ./update.sh"
                      set_color normal
                  end
              end
          end
      end
    '';
  };
}
