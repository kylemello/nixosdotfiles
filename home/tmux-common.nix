# Shared by home/tmux.nix (tmux on the Linux/macOS hosts) and home/psmux.nix
# (psmux on artemis's Windows side), so the two multiplexers stay one config.
# A plain attrset, not a module: both import it with `import ./tmux-common.nix`.
rec {
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

  # status-right after the mode indicator: zoom flag, clock, hostname. Each
  # side prepends its own indicator (tmux-mode-indicator has no psmux port).
  statusRightTail = "#[fg=${catppuccin.yellow},bg=${catppuccin.surface0}]#{?window_zoomed_flag, 󰹑 , }#[fg=${catppuccin.text},bg=${catppuccin.surface0}] %Y-%m-%d 󰥔 %I:%M:%S%p #[fg=${catppuccin.blue},bg=${catppuccin.surface0}]#[fg=${catppuccin.base},bg=${catppuccin.blue},bold] #h";

  # Copy-mode, clipboard, split/pane bindings and the Catppuccin look. Plain
  # tmux syntax that psmux parses unchanged.
  bindingsAndAppearance = ''
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
}
