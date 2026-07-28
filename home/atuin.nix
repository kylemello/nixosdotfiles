{ config, lib, pkgs, ... }:

# Atuin: one shell history, shared between artemis and ariane through the
# self-hosted server on gateway (hosts/sync-hub.nix).
#
# The hard requirement is that the *interface* does not change — only the data
# source. So every one of Atuin's own key bindings is turned off and Ctrl-R is
# handed to `_fzf_atuin_history` below, a clone of fzf.fish's
# `_fzf_search_history` (pinned rev 8920367, see home/fish.nix) with a single
# line swapped.
let
  cfg = config.kyle.atuin;

  # Atuin's `{time}` renders as `2026-07-28 12:14:01` (19 chars); fzf.fish's
  # default `fzf_history_time_format` is `%m-%d %H:%M:%S` -> `07-28 12:14:01`
  # (14). Measured against a real imported history on 2026-07-28; `--human`
  # makes no difference to `{time}`, and atuin has no time-format option, so
  # the `YYYY-` has to come off downstream to keep the column the same width.
  #
  # It has to be `sed -z`, and it has to be gnused: the records are NUL
  # separated (a command can contain newlines) and BSD sed has no -z. fish's
  # own `string replace` was tried first and is NOT an option — it drops NUL
  # bytes entirely, so the whole stream comes out empty. Verified both.
  #
  # Purely cosmetic: `time_prefix_regex` below strips whatever the time column
  # turns out to be, so the command that reaches the command line is correct
  # either way.
  trimYear = "${pkgs.gnused}/bin/sed -z -E 's/^[0-9]{4}-//'";
in
{
  options.kyle.atuin.enable = lib.mkEnableOption ''
    Atuin shell history synced through the gateway hub, presented behind
    fzf.fish's Ctrl-R interface.

    Off by default and enabled per-host in home/wsl.nix and home/darwin.nix,
    NOT in users/kyle/home.nix — that profile is imported by all four NixOS
    hosts, and atlas/gateway/nixosvm must stay byte-identical to a tree
    without this module. They also have no second machine to sync with, and
    an unregistered client would just log auth failures at auto_sync's
    5-minute cadence forever
  '';

  config = lib.mkIf cfg.enable {
    programs.atuin = {
      enable = true;

      # Atuin binds three keys of its own. ALL THREE are suppressed, because
      # the point of this module is that the interface is unchanged:
      #   --disable-ctrl-r    fzf.fish owns Ctrl-R (bound below)
      #   --disable-up-arrow  fish's own up-or-search stays
      #   --disable-ai        `bind "?"`, which is not in the brief's flag list
      #                       but is the one binding the other two leave behind.
      #                       In vi mode that shadows `?` (search-backward) in
      #                       normal mode AND, because atuin's own handler
      #                       declines to insert the character under
      #                       fish_vi_key_bindings, makes `?` do nothing at all
      #                       there. Verified against atuin 18.17.0: with all
      #                       three flags `atuin init fish` emits zero `bind`
      #                       lines; with only the first two it emits one.
      flags = [ "--disable-ctrl-r" "--disable-up-arrow" "--disable-ai" ];

      settings = {
        # The Home Manager example defaults to "prefix"; do not inherit it.
        search_mode = "fuzzy";
        filter_mode = "global";
        sync_address = "http://gateway:8888";
        auto_sync = true;
        sync_frequency = "5m";
        update_check = false;
      };
    };

    # A clone of fzf.fish's _fzf_search_history with the data source swapped
    # from `builtin history` to `atuin search`. `_fzf_wrapper`, `--multi`,
    # `--scheme=history`, the `History> ` prompt, the `fish_indent --ansi`
    # preview, the U+2502 separator and `$fzf_history_opts` are all upstream's,
    # verbatim.
    #
    # Deliberately dropped from upstream:
    #   * `builtin history merge` — no Atuin equivalent; the server is the
    #     merge point.
    #   * `$fzf_history_time_format` — upstream lets you re-format the time
    #     column via strftime. Atuin's `--format` has a fixed `{time}` and no
    #     strftime hook, so the variable cannot be honoured. `trimYear` above
    #     pins the column to upstream's *default* rendering; a user who had
    #     overridden the variable loses that override. Nobody here has.
    #
    # No `2>/dev/null` anywhere: if `atuin search` fails (an unset
    # ATUIN_SESSION, a locked db) its message must reach the terminal.
    # Swallowed, the only symptom would be a Ctrl-R that opens an empty list.
    programs.fish.functions._fzf_atuin_history = {
      description = "Search Atuin history. Replace the command line with the selected command.";
      body = ''
        set -f time_prefix_regex '^.*? │ '
        set -f commands_selected (
            atuin search --print0 --limit 10000 --format "{time} │ {command}" |
            ${trimYear} |
            _fzf_wrapper --read0 \
                --print0 \
                --multi \
                --scheme=history \
                --prompt="History> " \
                --query=(commandline) \
                --preview="string replace --regex '$time_prefix_regex' ''' -- {} | fish_indent --ansi" \
                --preview-window="bottom:3:wrap" \
                $fzf_history_opts |
            string split0 |
            string replace --regex $time_prefix_regex '''
        )

        if test $status -eq 0
            commandline --replace -- $commands_selected
        end

        commandline --function repaint
      '';
    };

    # mkAfter so this lands after home/fish.nix's `fish_vi_key_bindings`.
    # Ordering is belt-and-braces rather than load-bearing: that call erases
    # only *preset* bindings (`bind --erase --all --preset`), which is why the
    # repo's existing `bind \ct _fzf_search_directory` survives from before it.
    # Ordering against atuin's own init is moot — with the flags above it emits
    # no bindings at all.
    #
    # Both tables are needed: vi mode keeps separate insert-mode bindings.
    programs.fish.interactiveShellInit = lib.mkAfter ''
      bind \cr _fzf_atuin_history
      bind -M insert \cr _fzf_atuin_history
    '';
  };
}
