# Version + hashes live in ./_sources/terraform.json so they can be bumped
# automatically: run `nix run .#update-overlays`.
#
# Why this replaces nixpkgs' terraform: it is unfree, so cache.nixos.org does not
# carry it and every `nix flake update` that moved it recompiled it on each host.
# HashiCorp ships the same release prebuilt, so nothing is compiled here.
self: super:
let
  sources = builtins.fromJSON (builtins.readFile ./_sources/terraform.json);
  inherit (super.stdenv.hostPlatform) system;

  suffix = {
    x86_64-linux = "linux_amd64";
    aarch64-linux = "linux_arm64";
    x86_64-darwin = "darwin_amd64";
    aarch64-darwin = "darwin_arm64";
  }.${system};
in
{
  terraform = super.stdenv.mkDerivation rec {
    pname = "terraform";
    version = sources.version;

    src = super.fetchurl {
      url = "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_${suffix}.zip";
      hash = sources.hashes.${system};
    };

    nativeBuildInputs = [ super.unzip ];

    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;

    unpackPhase = ''
      runHook preUnpack
      mkdir -p source
      unzip -q $src -d source
      cd source
      runHook postUnpack
    '';

    # CHECKPOINT_DISABLE: `version` otherwise asks HashiCorp for the latest release.
    checkPhase = ''
      CHECKPOINT_DISABLE=1 ./terraform version
    '';

    doCheck = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      cp terraform $out/bin/

      runHook postInstall
    '';

    meta = with super.lib; {
      description = "HashiCorp's official Terraform CLI";
      homepage = "https://www.terraform.io";
      license = licenses.bsl11;
      platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      mainProgram = "terraform";
    };
  };
}
