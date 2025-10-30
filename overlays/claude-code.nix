# Override packages to use latest versions
# This is where you can pin specific packages to newer versions
# before they're updated in the stable nixpkgs channel

self: super: {
  # Override claude-code to version 2.0.27
  # This package is an npm package that uses buildNpmPackage
  claude-code = super.claude-code.overrideAttrs (oldAttrs: rec {
    version = "2.0.27";
    src = super.fetchzip {
      url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
      hash = "sha256-ZxwEnUWCtgrGhgtUjcWcMgLqzaajwE3pG7iSIfaS3ic=";
    };
  });
}
