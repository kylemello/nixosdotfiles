{ pkgs, ... }:

let
  catppuccin = {
    rosewater = "#f5e0dc";
    flamingo = "#f2cdcd";
    pink = "#f5c2e7";
    mauve = "#cba6f7";
    red = "#f38ba8";
    maroon = "#eba0ac";
    peach = "#fab387";
    yellow = "#f9e2af";
    green = "#a6e3a1";
    teal = "#94e2d5";
    sky = "#89dceb";
    sapphire = "#74c7ec";
    blue = "#89b4fa";
    lavender = "#b4befe";
    text = "#cdd6f4";
    subtext1 = "#bac2de";
    subtext0 = "#a6adc8";
    overlay2 = "#9399b2";
    overlay1 = "#7f849c";
    overlay0 = "#6c7086";
    surface2 = "#585b70";
    surface1 = "#45475a";
    surface0 = "#313244";
    base = "#1e1e2e";
    mantle = "#181825";
    crust = "#11111b";
  };

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
    historyLimit = 10000;
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
      mode-indicator
    ];

    # All other settings go into extraConfig
    extraConfig = ''
      # --- General Settings ---
      set -ga terminal-overrides ",xterm-256color*:Tc" # Enable True Color support
      setw -g pane-base-index 1

      # --- Keybindings ---
      bind-key C-space send-prefix

      # Scroll with mouse wheel
      bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'select-pane -t=; copy-mode -e; send-keys -M'"
      bind -n WheelDownPane select-pane -t= \; send-keys -M

      # Vi-mode copy bindings
      bind -T copy-mode-vi v send-keys -X begin-selection
      bind -T copy-mode-vi C-v send-keys -X rectangle-toggle
      bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel

      # Use system clipboard
      set -s set-clipboard on

      # Split window keeping the current path
      bind '"' split-window -v -c "#{pane_current_path}"
      bind % split-window -h -c "#{pane_current_path}"
      bind c new-window -c "#{pane_current_path}"

      # Vim-like pane navigation
      bind -r ^ last-window
      bind -r k select-pane -U
      bind -r j select-pane -D
      bind -r h select-pane -L
      bind -r l select-pane -R

      # Pane resizing
      bind -r H resize-pane -L 5
      bind -r J resize-pane -D 5
      bind -r K resize-pane -U 5
      bind -r L resize-pane -R 5

      # --- Appearance (Catppuccin Mocha) ---

      # Default statusbar colors
      set -g status-style "fg=${catppuccin.text},bg=${catppuccin.base}"

      # Default window title colors
      setw -g window-status-style "fg=${catppuccin.subtext0},bg=${catppuccin.base}"
      setw -g window-status-current-style "fg=${catppuccin.rosewater},bg=${catppuccin.surface0},bold"

      # Pane border
      set -g pane-active-border-style "fg=${catppuccin.blue}"
      set -g pane-border-style "fg=${catppuccin.surface2}"

      # Message/command line colors
      set -g message-style "fg=${catppuccin.text},bg=${catppuccin.surface0}"
      set -g message-command-style "fg=${catppuccin.text},bg=${catppuccin.surface0}"

      # Status line left side
      set -g status-left-length 100
      set -g status-left "#[fg=${catppuccin.base},bg=${catppuccin.lavender},bold] #S #[fg=${catppuccin.lavender},bg=${catppuccin.base},nobold,nounderscore,noitalics]"

      # Status line right side
      set -g status-right-length 100
      set -g status-right "#{tmux_mode_indicator}#[fg=${catppuccin.yellow},bg=${catppuccin.surface0}]#{?window_zoomed_flag, 󰹑 , }#[fg=${catppuccin.text},bg=${catppuccin.surface0}] %Y-%m-%d 󰥔 %I:%M:%S%p #[fg=${catppuccin.blue},bg=${catppuccin.surface0}]#[fg=${catppuccin.base},bg=${catppuccin.blue},bold] #h #($HOME/.local/bin/distro_icon.sh || echo '') "

      # Window status
      set -g status-justify "left"
      setw -g window-status-current-format "#[fg=${catppuccin.base},bg=${catppuccin.pink}]#[fg=${catppuccin.base},bg=${catppuccin.pink},bold] #I  #W #[fg=${catppuccin.pink},bg=${catppuccin.base},nobold]"
      setw -g window-status-format "#[fg=${catppuccin.text},bg=${catppuccin.base}] #I  #W "
      setw -g window-status-activity-style "fg=${catppuccin.yellow},bg=${catppuccin.base}"

      # Clock mode
      set -g clock-mode-colour "${catppuccin.sky}"
      set -g clock-mode-style 12

      # Update status bar every second
      set -g status-interval 1
    '';
  };
}
