# nixpkgs bumped opencode to 2.2.5 with a node_modules hash that neither Linux
# nor Darwin reproduces. Upstream fixed it in NixOS/nixpkgs@c399e1b7fb with the
# hashes below. This only takes effect while nixpkgs still carries the stale
# hash, so it goes inert once nixos-unstable has the fix. Delete it then.
self: super:
let
  staleHash = "sha256-xfOVcw1+waLVNhFDwzOtzxrUSQEogvn88YomydOlhwc=";
in
{
  opencode =
    if super.opencode.node_modules.outputHash != staleHash then
      super.opencode
    else
      super.opencode.overrideAttrs (old: {
        node_modules = old.node_modules.overrideAttrs {
          outputHash =
            if super.stdenv.hostPlatform.isLinux then
              "sha256-prx9dX7kUvs/E3zopkaPk5LXh3xJAy5sZeum/W8L7cA="
            else
              "sha256-dIveiaiPFGSItwLyeMuPDxTE9gpvvnlTCB/+nG24qCc=";
        };
      });
}
