#!/usr/bin/env bash
# Bumps overlays/_sources/ollama.json to the latest upstream ollama release.
# Run via `nix run .#update-overlays` (which supplies curl/jq/nix on PATH).
# Arg $1: path to the JSON source file to (over)write.
set -euo pipefail

out="$1"
repo="ollama/ollama"
asset="ollama-linux-amd64.tar.zst"
old="$(cat "$out" 2>/dev/null || echo '{}')"

echo "  fetching releases..."
releases="$(curl -fsSL "https://api.github.com/repos/${repo}/releases?per_page=30")"

# Same guard as the infisical updater: a tag can appear before its binaries are
# attached, so take the newest release that actually carries the asset.
tag="$(jq -r --arg a "$asset" '
  [ .[]
    | select(.draft | not)
    | select(.prerelease | not)
    | select(any(.assets[]?; .name == $a))
  ] | .[0].tag_name // empty' <<<"$releases")"

if [ -z "$tag" ]; then
  echo "  ERROR: no release with a $asset found" >&2
  exit 1
fi
version="${tag#v}"

# The asset is ~1.4 GB, so don't re-download it just to recompute a hash we
# already have. This is the common case: most update runs change nothing.
if [ "$version" = "$(jq -r '.version // empty' <<<"$old")" ]; then
  echo "  already at v$version, nothing to fetch"
  exit 0
fi

echo "  latest release with assets: v$version (downloading ~1.4 GB)"
hash="$(nix store prefetch-file --json \
  "https://github.com/${repo}/releases/download/${tag}/${asset}" | jq -r .hash)"
printf '  %-15s %s\n' x86_64-linux "$hash"

jq -n --arg version "$version" --arg hash "$hash" \
  '{version: $version, hashes: {"x86_64-linux": $hash}}' > "$out"
echo "  wrote $out"
