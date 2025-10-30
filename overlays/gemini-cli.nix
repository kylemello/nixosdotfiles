self: super: {
  gemini-cli = super.gemini-cli.overrideAttrs (oldAttrs: rec {
    version = "0.10.0";
    src = super.fetchFromGitHub {
      owner = "google-gemini";
      repo = "gemini-cli";
      tag = "v${version}";
      hash = "sha256-h6JyiIh0+PI/5JHlztMKlXlK5XQC8x6V7Yq1VyboaXs=";
    };
    npmDepsHash = "sha256-4RsZAs9+Q7vnRiyA1OMXC185d9Y9k6mwG+QkOE+5Pas=";
    npmDeps = super.fetchNpmDeps {
        inherit src;
        name = "${oldAttrs.pname}-${version}-npm-deps";
        hash = npmDepsHash;
      };
  });
}
