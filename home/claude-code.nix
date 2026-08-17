{ lib, pkgs, config, ... }:
# Declarative slices of ~/.claude.json: the user-scope MCP servers, and the trust
# flag for the home directory (see homeTrust below). Everything here is merged in
# so every host that imports this module sees the same set — no per-machine
# `claude mcp add` needed.
#
# Auth is OAuth or a runtime-added token, so NOTHING secret lives here; the
# grants land in the OS keychain / Secret Service or in ~/.claude.json, not git.
#
# The `claude-code` package itself is installed via home/packages/misc.nix.
let
  # Added only on the machines that actually drive Claude Code interactively
  # (kyle.claude.enable — artemis and ariane), which keeps atlas/gateway/nixosvm
  # byte-identical while still ending the per-machine drift these servers had
  # accumulated: as measured 2026-07-28 they had been added with `claude mcp add`
  # and each lived on exactly one machine (git/kubernetes/atlassian-aegis on
  # artemis, teams-mcp on ariane). All are portable — `uvx` comes from `uv` and
  # `npx` from `nodejs_24`, both in home/packages/dev.nix, and the rest are plain
  # URLs.
  #
  # Declaring a server does NOT authenticate it: `atlassian-aegis` still needs one
  # interactive `/mcp` -> authenticate -> pick the `aegistherapies` site, once per
  # host. (That replaces the manual `claude mcp add` step documented in
  # ~/work/claude-plugins/README.md, which aegis-jira's creating-adt-tickets skill
  # hard-depends on by name.)
  workstationServers = {
    atlassian-aegis = {
      type = "http";
      url = "https://mcp.atlassian.com/v1/mcp/authv2";
    };
    home-assistant = {
      # HA's built-in "Model Context Protocol Server" integration, which the
      # docs expose at /api/mcp over Streamable HTTP. The legacy /mcp_server/sse
      # route still answers on this instance, but it is the older SSE transport
      # — prefer /api/mcp.
      #
      # UNLIKE atlassian-aegis, this one canNOT use `/mcp` -> authenticate.
      # HA's /.well-known/oauth-authorization-server is not RFC 8414 compliant
      # (verified 2026-08-02): it omits `issuer` and returns *relative* paths
      # ("/auth/authorize", "/auth/token", "/auth/revoke") where the spec wants
      # absolute URLs, so Claude Code's metadata validation rejects it before
      # the flow starts. Auth is therefore a long-lived access token instead.
      #
      # The token is a secret, so it is NOT declared here. It lives only in
      # ~/.claude.json as `headers.Authorization`, added per host with
      #   claude mcp add --scope user --transport http home-assistant \
      #     https://ha.kmello.dev/api/mcp --header "Authorization: Bearer <t>"
      # The jq merge below is recursive (`. * $d`) and this attrset declares no
      # `headers` key, so that locally-added header survives every activation.
      type = "http";
      url = "https://ha.kmello.dev/api/mcp";
    };
    git = {
      type = "stdio";
      command = "uvx";
      # `--with 'mcp<2'` is load-bearing. mcp-server-git 2026.7.10 calls
      # `@server.list_tools()`, which the mcp SDK removed in 2.0.0, so an
      # unpinned uvx resolves the newest SDK and the server dies on startup
      # with `AttributeError: 'Server' object has no attribute 'list_tools'`.
      # Claude Code surfaces that only as "Connection closed", which is why it
      # looked like a config problem. Broken on BOTH machines, not just one.
      # Drop the pin once mcp-server-git supports SDK 2.x.
      args = [ "--with" "mcp<2" "mcp-server-git" ];
      env = { };
    };
    kubernetes = {
      type = "stdio";
      command = "npx";
      args = [ "mcp-server-kubernetes" ];
      env = { };
    };
    teams-mcp = {
      type = "stdio";
      command = "npx";
      args = [ "-y" "@floriscornel/teams-mcp@latest" ];
      env = { };
    };
  };

  mcpServers = lib.optionalAttrs config.kyle.claude.enable workstationServers;

  # Claude Code refuses to PERSIST the trust decision when its cwd is exactly the
  # home directory. The accept handler branches on `os.homedir() === cwd()` and,
  # for that case, sets an in-process `sessionTrustAccepted` flag INSTEAD of
  # writing projects[cwd].hasTrustDialogAccepted into ~/.claude.json (read out of
  # the claude-code 2.1.221 bundle, 2026-08-07). So `claude` launched from ~ re-asks
  #   Quick safety check: Is this a project you created or one you trust?
  # on every single start, no matter how many times it is accepted. Writing the key
  # ourselves is the fix: the trust *check* reads it the same either way, and the
  # dialog component self-skips once it finds the folder already trusted. The flag
  # is only ever set, never cleared, so this survives Claude Code's own rewrites.
  #
  # The reason for that special case, and the trade-off being accepted here: with
  # cwd = ~, Claude Code treats ~/.claude/ as *project* settings, so the global
  # settings.json/hooks/MCP servers get counted as folder-supplied config — exactly
  # what the dialog exists to warn about. On top of that the trust check walks UP
  # the directory tree, so a trusted ~ transitively trusts everything beneath it:
  # any repo cloned anywhere under ~ from now on has its .claude/settings.json
  # allow rules, hooks and .mcp.json servers applied without a prompt. ~/work and
  # ~/personal were already trusted individually, so what this really widens is
  # newly-cloned paths.
  #
  # Gated on kyle.claude.enable, like workstationServers above, so
  # atlas/gateway/nixosvm — which nobody drives Claude Code from — keep the prompt.
  homeTrust = lib.optionalAttrs config.kyle.claude.enable {
    projects.${config.home.homeDirectory}.hasTrustDialogAccepted = true;
  };

  # Only what is declared above is managed; everything else in ~/.claude.json
  # (other projects, history, cached auth) is preserved by the deep-merge below.
  # Note the merge only ever ADDS: dropping a server from this set does not remove
  # it from a host that already has it — do that with `claude mcp remove`. Likewise
  # dropping homeTrust does not re-arm the prompt; clear the key by hand for that.
  desired = builtins.toJSON ({ inherit mcpServers; } // homeTrust);
in
{
  # For config.kyle.claude.enable above. Imported here as well as from the user
  # profiles so this module is self-contained; the module system dedupes by path.
  imports = [ ./claude.nix ];

  # ~/.claude.json is a mutable file Claude Code owns at runtime, so we can't render it
  # with home.file (that would clobber its state). Instead, idempotently deep-merge our
  # declared slices into it on each activation. `jq`'s `*` recursively merges objects,
  # so existing keys survive and ours are added/refreshed — including the single key
  # homeTrust adds under an existing projects[~] entry, which keeps its siblings.
  home.activation.claudeCodeJson =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      claudeJson="$HOME/.claude.json"
      desired='${desired}'
      jq=${pkgs.jq}/bin/jq
      if [ ! -e "$claudeJson" ]; then
        $DRY_RUN_CMD printf '%s\n' "$desired" > "$claudeJson"
        $DRY_RUN_CMD chmod 600 "$claudeJson"
      elif "$jq" -e . "$claudeJson" >/dev/null 2>&1; then
        tmp="$(mktemp "$claudeJson.XXXXXX")"
        if "$jq" --argjson d "$desired" '. * $d' "$claudeJson" > "$tmp"; then
          $DRY_RUN_CMD mv "$tmp" "$claudeJson"
        else
          rm -f "$tmp"
          echo "claude-code: failed to merge declared config into $claudeJson" >&2
        fi
      else
        echo "claude-code: $claudeJson is not valid JSON; skipping config merge" >&2
      fi
    '';
}
