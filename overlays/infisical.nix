# Version + hashes live in ./_sources/infisical.json so they can be bumped
# automatically: run `nix run .#update-overlays`.
self: super:
let
  sources = builtins.fromJSON (builtins.readFile ./_sources/infisical.json);
  inherit (super.stdenv.hostPlatform) system;

  suffix = {
    x86_64-linux = "linux_amd64";
    aarch64-linux = "linux_arm64";
    x86_64-darwin = "darwin_amd64";
    aarch64-darwin = "darwin_arm64";
  }.${system};
in
{
  infisical = super.stdenv.mkDerivation rec {
    pname = "infisical";
    version = sources.version;

    src = super.fetchurl {
      url = "https://github.com/Infisical/cli/releases/download/v${version}/cli_${version}_${suffix}.tar.gz";
      hash = sources.hashes.${system};
    };

    nativeBuildInputs = [ super.installShellFiles ];

    dontConfigure = true;
    dontStrip = true;

    unpackPhase = ''
      runHook preUnpack
      mkdir -p source
      tar -xzf $src -C source
      cd source
      runHook postUnpack
    '';

    buildPhase = ''
      chmod +x ./infisical
    '';

    checkPhase = ''
      ./infisical --version
    '';

    doCheck = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      cp infisical $out/bin/

      if [ -d completions ]; then
        installShellCompletion --cmd infisical \
          --bash completions/infisical.bash \
          --fish completions/infisical.fish \
          --zsh completions/infisical.zsh
      fi

      if [ -f manpages/infisical.1.gz ]; then
        installManPage manpages/infisical.1.gz
      fi

      runHook postInstall
    '';

    meta = with super.lib; {
      description = "The official Infisical CLI";
      homepage = "https://infisical.com";
      license = licenses.mit;
      platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    };
  };
}
