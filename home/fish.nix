{ pkgs, ... }:

{
  home = {
    sessionVariables = {
      MANPAGER="nvim +Man!";
      EDITOR = "nvim";
      VISUAL = "nvim";
      PNPM_HOME = "$HOME/.pnpm";
      UID = "$(id -u)";

      # Nix owns `claude` (the claude-code overlay from sadjow/claude-code-nix,
      # refreshed by `nix flake update`). Without this, the binary's own
      # updater reinstalls a native build into ~/.local/share/claude and puts a
      # symlink in ~/.local/bin, which then shadows the Nix one on PATH — that
      # had already happened on ariane (3 versions, 959 MB). Verified the
      # variable is recognised: DISABLE_AUTOUPDATER appears in the binary.
      DISABLE_AUTOUPDATER = "1";
    };

    sessionPath = [
      "$HOME/.pnpm"
      # Was hardcoded to /home/kyle/.local/bin, which is a dead entry on the
      # ariane Mac (its home is /Users/kyle). $HOME is expanded by the shell,
      # so it resolves correctly on both.
      "$HOME/.local/bin"
      "$HOME/.config/emacs/bin"
    ];

    shellAliases = {
      llr="eza -laghF --git --icons --time-style=relative --group-directories-first";
      ll="eza -laghF --git --icons --time-style='+%Y-%m-%d %I:%M:%S %p' --group-directories-first";
      l="eza -lghF --git --icons --time-style='+%Y-%m-%d %I:%M:%S %p' --group-directories-first";
      wan="curl checkip.amazonaws.com";
      mysql="mysql --skip-ssl";
      yolo="git commit -m \"$(curl -s https://whatthecommit.com/index.txt)\"";
      cd="z";
    };
  };

  programs.fish = {
    enable = true;

    plugins = [
      {
        name = "plugin-git";
        src = pkgs.fishPlugins.plugin-git.src;
      }
      {
        name = "plugin-fzf";
        src = pkgs.fetchFromGitHub {
          owner = "PatrickF1";
          repo = "fzf.fish";
          rev = "8920367cf85eee5218cc25a11e209d46e2591e7a";
          sha256 = "sha256-T8KYLA/r/gOKvAivKRoeqIwE2pINlxFQtZJHpOy9GMM=";
        };
      }
      {
        name = "tmux-budimanjojo";
        src = pkgs.fetchFromGitHub {
          owner = "budimanjojo";
          repo = "tmux.fish";
          rev = "db0030b7f4f78af4053dc5c032c7512406961ea5";
          sha256 = "sha256-rRibn+FN8VNTSC1HmV05DXEa6+3uOHNx03tprkcjjs8=";
        };
      }
      {
        name = "catppuccin-fish";
        src = pkgs.fetchFromGitHub {
          owner = "catppuccin";
          repo = "fish";
          rev = "6a85af2ff722ad0f9fbc8424ea0a5c454661dfed";
          sha256 = "sha256-Hq9UXB99kmbWKUVFDeJL790P8ek+xZR5LDvS+Qih+N4=";
        };
      }
      {
        name = "zoxide-kidonng";
        src = pkgs.fetchFromGitHub {
          owner = "kidonng";
          repo = "zoxide.fish";
          rev = "bfd5947bcc7cd01beb23c6a40ca9807c174bba0e";
          sha256 = "sha256-Hq9UXB99kmbWKUVFDeJL790P8ek+xZR5LDvS+Qih+N4=";
        };
      }
    ];

    functions = {
      git-clean-gone = {
        description = "Delete local branches whose remote upstream is gone";
        body = ''
          git fetch --prune
          set -l branches (git for-each-ref --format '%(refname:short) %(upstream:track)' refs/heads | string match -r --groups-only '^(\S+) \[gone\]$')
          if test (count $branches) -eq 0
              echo "No gone branches to delete."
              return 0
          end
          echo "The following branches will be deleted:"
          for branch in $branches
              echo "  $branch"
          end
          read -l -P 'Delete these branches? [y/N] ' confirm
          switch $confirm
              case Y y
                  for branch in $branches
                      git branch -D $branch
                  end
              case '*'
                  echo "Aborted."
                  return 1
          end
        '';
      };

      # Hand-written on artemis as ~/.config/fish/functions/q.fish and unknown
      # to Nix, so it existed on exactly one machine. Moved here verbatim apart
      # from the platform string, which was hardcoded to "NixOS/WSL2" and is
      # wrong on macOS.
      #
      # Transcription note: inside a Nix indented string a literal `''` must be
      # written `'''` and a literal `${` must be written `''${`. The original
      # has two `''` (the empty replacement arguments on the `string replace`
      # line) and no `${`; both were escaped. `\r`, `\n`, `\033` and the
      # backticks need no escaping — `\` is not special in a Nix `''` string.
      q = {
        description = "AI command suggestion";
        body = ''
          # 1. Parse flags: --opus, --haiku (default sonnet)
          argparse 'opus' 'haiku' -- $argv; or return 1

          # 2. Build query from remaining args, bail if empty
          set -l query (string join " " $argv)
          if test -z "$query"
              echo "Usage: q <describe what you want>" >&2
              return 1
          end

          # 3. Select model
          set -l model sonnet
          if set -q _flag_opus;  set model opus;  end
          if set -q _flag_haiku; set model haiku; end

          # 4. Static waiting message (background spinners block claude in fish)
          printf "  ⠹ thinking...\r" >&2

          # 5. Call Claude
          set -l system_prompt "You are a command generator for fish shell on ${
            if pkgs.stdenv.isDarwin then "macOS (nix-managed)" else "NixOS/WSL2"
          }. Output ONLY the raw shell command. No explanations, no markdown, no backticks, no code blocks. If multiple commands are needed, join with && or ; on one line."
          set -l response (claude -p --model $model --effort low --tools "" --no-session-persistence --system-prompt "$system_prompt" "$query" 2>/dev/null)
          set -l exit_code $status

          # 6. Clear waiting message
          printf "\r\033[K" >&2

          # 7. Error handling
          if test $exit_code -ne 0; or test -z "$response"
              set_color red >&2; echo "  Error getting suggestion" >&2; set_color normal >&2
              return 1
          end

          # 8. Strip formatting (code blocks, backticks)
          if string match -rq '^```' $response[1]
              set response $response[2..-2]
          end
          set -l cmd (string join "\n" $response | string replace -r '^\`' ''' | string replace -r '\`$' ''' | string trim)

          # 9. Display command
          echo >&2
          echo "  "(set_color bryellow)$cmd(set_color normal) >&2
          echo >&2

          # 10. Prompt: single keypress, no Enter needed
          read -l -P "  "(set_color brblack)"(r)un  (c)opy  (n)ope "(set_color normal) -n 1 action

          switch $action
              case r y
                  echo >&2
                  eval $cmd
              case c
                  printf '%s' $cmd | fish_clipboard_copy
                  echo "  Copied." >&2
              case '*'
                  echo "  Cancelled." >&2
          end
        '';
      };

      fish_prompt = ''
        set -l last_status $status
        set -l normal (set_color normal)
        set -l status_color (set_color brgreen)
        set -l cwd_color (set_color $fish_color_cwd)
        set -l vcs_color (set_color brpurple)
        set -l prompt_status ""

        # Since we display the prompt on a new line allow the directory names to be longer.
        set -q fish_prompt_pwd_dir_length
        or set -lx fish_prompt_pwd_dir_length 0

        # Color the prompt differently when we're root
        set -l suffix '❯'
        if functions -q fish_is_root_user; and fish_is_root_user
                if set -q fish_color_cwd_root
                        set cwd_color (set_color $fish_color_cwd_root)
                end
                set suffix '#'
        end

        # Color the prompt in red on error
        if test $last_status -ne 0
                set status_color (set_color $fish_color_error)
                set prompt_status $status_color "[" $last_status "]" $normal
        end

        echo -s (prompt_login) ' ' $cwd_color (prompt_pwd) $vcs_color (fish_vcs_prompt) $normal ' ' $prompt_status
        echo -n -s $status_color $suffix ' ' $normal
      '';
    };

    interactiveShellInit = ''
      bind \ct _fzf_search_directory
      bind -M insert \ct _fzf_search_directory
      fish_vi_key_bindings
      set -g fish_greeting
      set fish_cursor_default block
      set fish_cursor_insert line
      set fish_cursor_visual underscore
    '';
  };
}
