#!/usr/bin/env bash
# Bumps overlays/_sources/terraform.json to the latest stable Terraform release.
# Run via `nix run .#update-overlays` (which supplies curl/jq/nix on PATH).
# Arg $1: path to the JSON source file to (over)write.
set -euo pipefail

out="$1"

# The endpoint terraform itself checks. Unlike releases.hashicorp.com's index it
# names only the current stable release, so no filtering out alphas and rcs.
echo "  fetching latest version..."
version="$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)"

if [ -z "$version" ] || [ "$version" = "null" ]; then
  echo "  ERROR: no current_version from the checkpoint API" >&2
  exit 1
fi
echo "  latest release: v$version"

systems=(x86_64-linux aarch64-linux x86_64-darwin aarch64-darwin)
declare -A suffix=(
  [x86_64-linux]=linux_amd64
  [aarch64-linux]=linux_arm64
  [x86_64-darwin]=darwin_amd64
  [aarch64-darwin]=darwin_arm64
)

hashes="{}"
for s in "${systems[@]}"; do
  url="https://releases.hashicorp.com/terraform/${version}/terraform_${version}_${suffix[$s]}.zip"
  printf '  %-15s ' "$s"
  h="$(nix store prefetch-file --json "$url" 2>/dev/null | jq -r .hash)"
  echo "$h"
  hashes="$(jq --arg k "$s" --arg v "$h" '. + {($k): $v}' <<<"$hashes")"
done

jq -n --arg version "$version" --argjson hashes "$hashes" \
  '{version: $version, hashes: $hashes}' > "$out"
echo "  wrote $out"
