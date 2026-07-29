{ lib, pkgs, config, ... }:
# Declarative Claude Code MCP servers, pointing at the home-lab MetaMCP gateway
# (https://mcp.kmello.dev). This registers user-scope MCP servers so every host that
# imports this module sees the same set — no per-machine `claude mcp add` needed.
#
# Auth is OAuth, so NOTHING secret lives here: after a rebuild, run
#   claude mcp login personal
# ONCE per host to grant the token (stored in the OS keychain / Secret Service, not git).
#
# The `claude-code` package itself is installed via home/packages/misc.nix.
let
  # Extend this to add more endpoints later, e.g. a `work` endpoint on work hosts.
  #
  # Split in two on purpose. This module is imported by users/kyle/home.nix, so it
  # reaches all four NixOS hosts; `personal` has been deployed to all of them since
  # 2026-07-19 and stays there. The `workstation` set below is added only on the
  # machines that actually drive Claude Code interactively (kyle.claude.enable —
  # artemis and ariane), which keeps atlas/gateway/nixosvm byte-identical while
  # still ending the per-machine drift these four servers had accumulated: as
  # measured 2026-07-28 they had been added with `claude mcp add` and each lived
  # on exactly one machine (git/kubernetes/atlassian-aegis on artemis, teams-mcp
  # on ariane). All four are portable — `uvx` comes from `uv` and `npx` from
  # `nodejs_24`, both in home/packages/dev.nix, and the rest are plain URLs.
  #
  # Declaring a server does NOT authenticate it: `personal` still needs
  # `claude mcp login personal`, and `atlassian-aegis` still needs one interactive
  # `/mcp` -> authenticate -> pick the `aegistherapies` site, once per host. (That
  # replaces the manual `claude mcp add` step documented in ~/work/claude-plugins/README.md,
  # which aegis-jira's creating-adt-tickets skill hard-depends on by name.)
  baseServers = {
    personal = {
      type = "http";
      url = "https://mcp.kmello.dev/metamcp/personal/mcp";
    };
  };

  workstationServers = {
    atlassian-aegis = {
      type = "http";
      url = "https://mcp.atlassian.com/v1/mcp/authv2";
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

  mcpServers =
    baseServers
    // lib.optionalAttrs config.kyle.claude.enable workstationServers;

  # Only the servers declared above are managed; everything else in ~/.claude.json
  # (projects, history, cached auth) is preserved by the deep-merge below. Note the
  # merge only ever ADDS: dropping a server from this set does not remove it from
  # a host that already has it — do that with `claude mcp remove`.
  desired = builtins.toJSON { inherit mcpServers; };
in
{
  # For config.kyle.claude.enable above. Imported here as well as from the user
  # profiles so this module is self-contained; the module system dedupes by path.
  imports = [ ./claude.nix ];

  # ~/.claude.json is a mutable file Claude Code owns at runtime, so we can't render it
  # with home.file (that would clobber its state). Instead, idempotently deep-merge our
  # declared servers into it on each activation. `jq`'s `*` recursively merges objects,
  # so existing keys survive and our servers are added/refreshed.
  home.activation.claudeCodeMcpServers =
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
          echo "claude-code: failed to merge MCP servers into $claudeJson" >&2
        fi
      else
        echo "claude-code: $claudeJson is not valid JSON; skipping MCP server merge" >&2
      fi
    '';
}
