self: super: {
  infisical = super.stdenv.mkDerivation rec {
    pname = "infisical";
    version = "0.43.20";

    src =
      let
        inherit (super.stdenv.hostPlatform) system;
        selectSystem = attrs: attrs.${system};

        suffix = selectSystem {
          x86_64-linux = "linux_amd64";
          aarch64-linux = "linux_arm64";
          x86_64-darwin = "darwin_amd64";
          aarch64-darwin = "darwin_arm64";
        };

        hash = selectSystem {
          x86_64-linux = "sha256-SzQ2b7fpdLX35H1uW+gZfi8w7Z5SUWd+3QdYehwZXCM=";
          aarch64-linux = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          x86_64-darwin = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          aarch64-darwin = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        };
      in
      super.fetchurl {
        url = "https://github.com/Infisical/cli/releases/download/v${version}/cli_${version}_${suffix}.tar.gz";
        sha256 = hash;
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

