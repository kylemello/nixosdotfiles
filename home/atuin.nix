{ config, lib, pkgs, ... }:

# Atuin: one shell history, shared between artemis and ariane through the
# self-hosted server on gateway (hosts/sync-hub.nix).
#
# The hard requirement is that the *interface* does not change — only the data
# source. So every one of Atuin's own key bindings is turned off and Ctrl-R is
# handed to `_fzf_atuin_history` below, a clone of fzf.fish's
# `_fzf_search_history` (pinned rev 8920367, see home/fish.nix) with the data
# source swapped and timing columns added.
let
  cfg = config.kyle.atuin;

  # The picker reads Atuin's SQLite database directly rather than shelling out
  # to `atuin search --format`. That is a deliberate trade and the reason is
  # precision: Atuin's `{duration}` placeholder is *already humanized* by the
  # time it reaches the format string — it renders 3271ms as "3s" and 11002ms as
  # "11s", with no access to the underlying value and no strftime-style hook. The
  # prompt (home/fish.nix, __prompt_format_duration) reports the same commands as
  # "3.27s" and "11.00s", and a picker that disagreed with the prompt about how
  # long a command took would be worse than no timing at all.
  #
  # What that costs: this couples to Atuin's `history` table, which is an
  # internal, not a published interface. Verified against atuin 18.18.1. A future
  # migration that renames a column breaks Ctrl-R loudly (sqlite3 prints the
  # error, see the no-2>/dev/null rule below) rather than silently emptying the
  # list. `where deleted_at is null` reproduces the `filter_mode = "global"` set
  # below, and fzf does all the matching, so Atuin's own search_mode/filter_mode
  # are not consulted and nothing is lost by bypassing them.
  #
  # Held in the store as a file so it reaches sqlite3 on stdin. The query is full
  # of single quotes and the fish function is not the place to re-quote them.
  #
  # NOTE: the duration arithmetic here is a second implementation of
  # __prompt_format_duration in home/fish.nix. The formats MUST agree — that
  # agreement is the entire justification for reading SQLite. It is duplicated
  # rather than shared because sharing would mean invoking a fish function once
  # per row, 10,000 times, on every Ctrl-R. Change one, change the other.
  historyQuery = pkgs.writeText "atuin-history-picker.sql" ''
    with recent as (
      select timestamp, command,
        -- Stored as "ariane:kyle" / "artemis:kyle"; only the machine matters.
        case when instr(hostname, ':') > 0
             then substr(hostname, 1, instr(hostname, ':') - 1)
             else hostname end as host,
        -- Contract $HOME to ~ for both platforms' layouts. Doing this for the
        -- *other* host's prefix too is safe precisely because `host` is shown
        -- next to it: ~/nixosdotfiles, ~/personal and others exist on both
        -- machines, so the path alone would be ambiguous.
        case when cwd in ('/Users/kyle', '/home/kyle') then '~'
             when cwd like '/Users/kyle/%' then '~' || substr(cwd, 12)
             when cwd like '/home/kyle/%'  then '~' || substr(cwd, 11)
             else cwd end as dir,
        -- exit < 0 is Atuin's marker for a command with no recorded end: still
        -- running, or the shell died first. Rendering that as a green check
        -- against a 0s duration would be a lie, hence ⋯ and —. Signal deaths
        -- are NOT this case; those record properly (130 for Ctrl-C).
        case when exit = 0 then '✓'
             when exit < 0 then '⋯'
             else '✗' || exit end as flag,
        case when exit < 0 then '—'
             when duration / 1000000 < 1000  then (duration / 1000000) || 'ms'
             -- Integer-divide before scaling so this floors to hundredths the
             -- same way `math -s2 "floor($ms / 10) / 100"` does in the prompt;
             -- rounding would render 59999ms as "60.00s".
             when duration / 1000000 < 60000 then printf('%.2fs', (duration / 10000000) / 100.0)
             when duration / 1000000000 >= 3600
               then printf('%dh%02dm%02ds', duration / 1000000000 / 3600,
                           duration / 1000000000 % 3600 / 60, duration / 1000000000 % 60)
             else printf('%dm%02ds', duration / 1000000000 / 60, duration / 1000000000 % 60)
        end as dur
      from history
      where deleted_at is null
      order by timestamp desc
      limit 10000
    )
    -- Columns are padded with substr(), never printf('%-4s'): printf pads to a
    -- byte count, and every symbol above is multibyte. printf('%-5s', '✓') emits
    -- three display columns while '✗130' emits six, which is exactly the ragged
    -- output this layout exists to avoid. sqlite3's substr() counts characters.
    --
    -- Both pads widen without ever truncating. Clipping the field instead would
    -- silently turn a 120-hour duration into "h49m47s" and exit code 1000 into
    -- "✗100" — wrong values, rendered as if correct.
    select host || ' │ ' || dir || ' │ '
        || strftime('%m-%d %H:%M:%S', timestamp / 1000000000, 'unixepoch', 'localtime') || ' '
        || (case when length(flag) >= 4 then flag else substr(flag || '    ', 1, 4) end) || ' '
        || (case when length(dur) >= 9 then dur else substr('         ' || dur, -9) end)
        || ' │ ' || command
    from recent
    -- Repeated deliberately: SQLite does not promise that scanning a CTE
    -- preserves the ORDER BY inside it. The inner one picks *which* 10,000 rows,
    -- this one fixes the order they are shown in.
    order by timestamp desc
  '';
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
        # Only reached by `atuin search` on the command line — the Ctrl-R picker
        # below queries SQLite and matches with fzf, so this does not affect it.
        search_mode = "fuzzy";
        filter_mode = "global";
        sync_address = "http://gateway:8888";
        auto_sync = true;
        sync_frequency = "5m";
        update_check = false;
      };
    };

    # A clone of fzf.fish's _fzf_search_history. `_fzf_wrapper`, `--multi`,
    # `--scheme=history`, the `History> ` prompt, the `fish_indent --ansi`
    # preview, the U+2502 separator and `$fzf_history_opts` are all upstream's.
    #
    # Each row carries four │-delimited fields:
    #
    #     host │ directory │ <start time> <exit> <duration> │ command
    #
    # and fzf is told to show the last two and search only the command:
    #
    #   --with-nth=3..  hides host and directory from the list; they still ride
    #                   along on the line, which is how the preview gets them.
    #                   80 columns cannot fit a path (they reach 56 characters
    #                   here) and a readable command at once.
    #   --nth=2         restricts matching to the command alone. Typing "130"
    #                   finds `ping -c 130 gw` and does NOT drag in every row
    #                   whose exit code was ✗130.
    #
    # --nth indexes the line *as --with-nth transformed it*, not the original
    # (verified, fzf 0.74.2): after --with-nth=3.. only two fields remain, so
    # this is 2 and not 4. --nth=4 silently matches nothing at all.
    #
    # Command goes last so recovering it is exact. host, directory and the
    # metadata never contain │, so dropping the first three │-delimited fields
    # is unambiguous no matter what the command itself holds — `echo a │ grep b`
    # survives intact. Upstream's `^.*? │ ` prefix strip could not promise that.
    #
    # Deliberately dropped from upstream:
    #   * `builtin history merge` — no Atuin equivalent; the server is the
    #     merge point.
    #   * `$fzf_history_time_format` — upstream lets you re-format the time
    #     column via strftime. It cannot be honoured here: the format is built
    #     in SQL, before fish ever sees the row. Nobody here had overridden it.
    #
    # No `2>/dev/null` anywhere: if the query fails (a moved database, a schema
    # migration) its message must reach the terminal. Swallowed, the only
    # symptom would be a Ctrl-R that opens an empty list.
    programs.fish.functions._fzf_atuin_history = {
      description = "Search Atuin history with timings. Replace the command line with the selected command.";
      body = ''
        set -f data_home $XDG_DATA_HOME
        test -n "$data_home"; or set -f data_home $HOME/.local/share

        set -f field_prefix_regex '^([^│]*│){3}\s*'

        # sqlite3 cannot emit NUL-separated records, and the reason is not
        # obvious: its CLI rewrites control characters into caret notation on the
        # way out, so char(0) vanishes and char(30) arrives as a literal "^^".
        # `--ascii` is the way out — that mode's own record separator is a real
        # 0x1e byte, written raw, and newlines *inside* a value are left alone,
        # which is what keeps multi-line commands whole. tr then swaps 0x1e for
        # the NUL that --read0 wants; a plain byte swap, identical on BSD and
        # GNU tr, which is why this no longer needs gnused.
        set -f commands_selected (
            ${pkgs.sqlite}/bin/sqlite3 --ascii "file:$data_home/atuin/history.db?mode=ro" < ${historyQuery} |
            ${pkgs.coreutils}/bin/tr '\036' '\000' |
            _fzf_wrapper --read0 \
                --print0 \
                --multi \
                --scheme=history \
                --prompt="History> " \
                --query=(commandline) \
                --delimiter=" │ " \
                --with-nth=3.. \
                --nth=2 \
                --preview="printf '%s  %s\n\n' (string split --max 2 ' │ ' -- {})[1..2]; string replace --regex '$field_prefix_regex' ''' -- {} | fish_indent --ansi" \
                --preview-window="bottom:5:wrap" \
                $fzf_history_opts |
            string split0 |
            string replace --regex $field_prefix_regex '''
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
