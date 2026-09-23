{ pkgs, ... }:

let
  common = import ./tmux-common.nix;
  inherit (common) catppuccin;

  suspend = pkgs.tmuxPlugins.mkTmuxPlugin {
    pluginName = "suspend";
    version = "1a2f806666e0bfed37535372279fa00d27d50d14";
    src = pkgs.fetchFromGitHub {
      owner = "MunifTanjim";
      repo = "tmux-suspend";
      rev = "1a2f806666e0bfed37535372279fa00d27d50d14";
      sha256 = "sha256-+1fKkwDmr5iqro0XeL8gkjOGGB/YHBD25NG+w3iW+0g=";
    };
  };
in
{
  programs.tmux = {
    enable = true;
    # Corresponds to your general settings
    baseIndex = 1;
    escapeTime = 1;
    historyLimit = 50000;
    keyMode = "vi";
    mouse = true;
    prefix = "C-space";
    terminal = "tmux-256color";
    plugins = with pkgs.tmuxPlugins; [
      suspend
      sensible
      {
        plugin = resurrect;
        extraConfig = ''
          set -g @resurrect-capture-pane-contents 'on'
          set -g @resurrect-strategy-nvim 'session'
        '';
      }
      {
        plugin = continuum;
        extraConfig = ''
          set -g @continuum-boot 'off'
          set -g @continuum-restore 'off'
          set -g @continuum-save-interval '1'
        '';
      }
      {
        plugin = mode-indicator;
        extraConfig = ''
          # Status line right side
          set -g status-right-length 100
          set -g status-right "#{tmux_mode_indicator}${common.statusRightTail} #($HOME/.local/bin/distro_icon.sh || echo '') "
        '';
      }
    ];

    # All other settings go into extraConfig
    extraConfig = ''
      # --- General Settings ---
      set -ga terminal-overrides ",xterm-256color*:Tc" # Enable True Color support
      # setw -g pane-base-index 1

      # --- Keybindings ---
      # bind-key C-space send-prefix

      # Scroll with mouse wheel
      bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'select-pane -t=; copy-mode -e; send-keys -M'"
      bind -n WheelDownPane select-pane -t= \; send-keys -M

      ${common.bindingsAndAppearance}'';
  };
}
