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
  mcpServers = {
    personal = {
      type = "http";
      url = "https://mcp.kmello.dev/metamcp/personal/mcp";
    };
  };

  # Only the servers declared above are managed; everything else in ~/.claude.json
  # (projects, history, cached auth) is preserved by the deep-merge below.
  desired = builtins.toJSON { inherit mcpServers; };
in
{
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
