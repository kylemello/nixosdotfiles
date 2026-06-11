#!/usr/bin/env bash
# Bumps overlays/_sources/infisical.json to the latest Infisical CLI release.
# Run via `nix run .#update-overlays` (which supplies curl/jq/nix on PATH).
# Arg $1: path to the JSON source file to (over)write.
set -euo pipefail

out="$1"
repo="Infisical/cli"
old="$(cat "$out" 2>/dev/null || echo '{}')"

echo "  fetching releases..."
releases="$(curl -fsSL "https://api.github.com/repos/${repo}/releases?per_page=30")"

# The newest tag sometimes ships before its binaries are attached (e.g. an
# asset-less v0.43.92). Pick the latest non-draft, non-prerelease release that
# actually has the linux_amd64 tarball.
tag="$(jq -r '
  [ .[]
    | select(.draft | not)
    | select(.prerelease | not)
    | select(any(.assets[]?; .name | test("^cli_.*_linux_amd64\\.tar\\.gz$")))
  ] | .[0].tag_name // empty' <<<"$releases")"

if [ -z "$tag" ]; then
  echo "  ERROR: no release with a linux_amd64 asset found" >&2
  exit 1
fi
version="${tag#v}"
echo "  latest release with assets: v$version"

systems=(x86_64-linux aarch64-linux x86_64-darwin aarch64-darwin)
declare -A suffix=(
  [x86_64-linux]=linux_amd64
  [aarch64-linux]=linux_arm64
  [x86_64-darwin]=darwin_amd64
  [aarch64-darwin]=darwin_arm64
)

hashes="{}"
for s in "${systems[@]}"; do
  url="https://github.com/${repo}/releases/download/v${version}/cli_${version}_${suffix[$s]}.tar.gz"
  printf '  %-15s ' "$s"
  if h="$(nix store prefetch-file --json "$url" 2>/dev/null | jq -r .hash)" \
     && [ -n "$h" ] && [ "$h" != "null" ]; then
    echo "$h"
  else
    # Fall back to the previously-pinned hash if this platform has no asset.
    h="$(jq -r --arg k "$s" '.hashes[$k] // empty' <<<"$old")"
    if [ -z "$h" ]; then
      echo "no asset and no prior hash -> skipping"
      continue
    fi
    echo "no asset, keeping prior hash"
  fi
  hashes="$(jq --arg k "$s" --arg v "$h" '. + {($k): $v}' <<<"$hashes")"
done

jq -n --arg version "$version" --argjson hashes "$hashes" \
  '{version: $version, hashes: $hashes}' > "$out"
echo "  wrote $out"
