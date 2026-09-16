{ config, pkgs, lib, ... }:

# `q` — ask Claude for a shell command, then run / edit / copy / refine it.
#
# Two pieces: home/q/q.py does all the work and all the interface, and the fish
# function below is a ~15-line shim whose only jobs are to capture two things
# Python cannot see ($status and $history) and to `eval` what comes back.
#
# It was a pure fish function until 2026-09-15 (home/fish.nix). What forced the
# port is documented at the top of q.py; the short version is that a fish
# spinner cannot animate in front of the `claude` call it belongs to, and
# parsing free-form model output with `string` builtins crashed the whole
# function the first time the model answered in prose.
#
# NOT behind a `kyle.q.enable` option, unlike most modules here: `q` existed on
# all five hosts as part of home/fish.nix, and every option in this repo is
# off-by-default and enabled only in home/wsl.nix + home/darwin.nix — which
# would have quietly dropped `q` from atlas, gateway and nixosvm. Nothing about
# it is machine-specific, so there is nothing to gate on.
let
  platform =
    if pkgs.stdenv.hostPlatform.isDarwin
    then "macOS (nix-managed)"
    else "NixOS/WSL2";

  # rich is the only dependency; everything else q.py uses is stdlib. The
  # interpreter has to come from Nix because there is no other Python on these
  # machines — home/packages/dev.nix ships `uv` with no interpreter behind it.
  pyEnv = pkgs.python3.withPackages (ps: [ ps.rich ]);

  # writeShellScriptBin, not writeShellApplication: the latter pulls shellcheck,
  # a heavy and often-uncached Haskell build. See CLAUDE.md.
  q-helper = pkgs.writeShellScriptBin "q-helper" ''
    set -euo pipefail

    # Absolute store paths, resolved here rather than looked up on PATH, for the
    # same reason home/wip.nix pins its WIP_* contract: `q` is invoked from an
    # interactive shell today, but PATH drift must not be able to silently
    # change which claude it talks to.
    export Q_CLAUDE=${pkgs.claude-code}/bin/claude
    export Q_PLATFORM=${lib.escapeShellArg platform}

    # Nix already knows these, so the model may as well: it is the difference
    # between being told `ls -la` and being told `ll`.
    export Q_ALIASES=${lib.escapeShellArg (lib.concatStringsSep "\n"
      (lib.mapAttrsToList (n: v: "${n}=${v}") config.home.shellAliases))}

    # git for the branch in the context block; the probe list in q.py uses
    # shutil.which against the *user's* PATH, which is inherited, so it still
    # sees eza/fd/rg and friends.
    export PATH="${lib.makeBinPath (with pkgs; [ git coreutils ])}:$PATH"

    # -s -E: ignore ~/.local/lib site-packages and every PYTHON* variable, so a
    # stray user install cannot shadow the pinned rich. Deliberately NOT -I,
    # which implies -P and would drop the script's own directory from sys.path
    # if this ever grows a second module.
    exec ${pyEnv}/bin/python3 -s -E ${./q/q.py} "$@"
  '';
in
{
  home.packages = [ q-helper ];

  # Owned by this module rather than home/fish.nix so the two halves stay
  # together — the same split home/atuin.nix uses for _fzf_atuin_history.
  programs.fish.functions.q = {
    description = "AI command suggestion";
    body = ''
      # MUST be the first line: at function entry $status is still the exit code
      # of the last thing typed at the prompt, which is all `q --fix` needs.
      # Reading it after any other command destroys it.
      set -l last_status $status

      # $history[1] is this very `q --fix`, so walk back to the first entry that
      # is not a q invocation. Five is enough to get past a couple of retries.
      set -l prev ""
      for h in $history[1..5]
          if not string match -qr '^\s*q(\s|$)' -- $h
              set prev $h
              break
          end
      end

      # Command substitution DOES propagate the helper's exit status, but only
      # through $pipestatus once `string collect` is in the pipe — and collect
      # is what keeps a multi-line suggestion as one string instead of a list
      # that `eval` would splice together with spaces.
      set -l cmd (q-helper --last-status $last_status --last-command $prev -- $argv | string collect)
      set -l rc $pipestatus[1]

      # 0 = run it, 1 = nothing to do (the helper already said so on stderr),
      # 2 = failed. See the contract at the top of home/q/q.py.
      switch $rc
          case 0
              test -n "$cmd"; or return 1
              # `eval` inside a function bypasses both fish history and atuin's
              # preexec hook, so the command would otherwise be unrecallable.
              history append -- $cmd
              eval $cmd
          case 2
              return 1
      end
    '';
  };
}
