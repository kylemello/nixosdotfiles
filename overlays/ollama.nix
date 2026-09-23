# Version + hash live in ./_sources/ollama.json so they can be bumped
# automatically: run `nix run .#update-overlays`.
#
# Why this replaces nixpkgs' ollama-cuda: that derivation compiles the ggml CUDA
# backend locally and is not on cache.nixos.org (nixpkgs does not redistribute
# binaries built against the CUDA toolkit), so every `nix flake update` that
# moved nixpkgs made artemis recompile it before it could switch. Upstream ships
# the same release prebuilt with the CUDA runtime bundled, so nothing is ever
# compiled here — a bump is a 1.4 GB download instead of a ~2 GB kernel build.
#
# Only x86_64-linux is defined: artemis is the only host that runs ollama, and
# the tarballs are large enough that there is no reason to have the updater
# prefetch platforms nothing here uses.
self: super:
let
  sources = builtins.fromJSON (builtins.readFile ./_sources/ollama.json);
in
super.lib.optionalAttrs (super.stdenv.hostPlatform.system == "x86_64-linux") {
  ollama-cuda = super.stdenv.mkDerivation {
    pname = "ollama-cuda";
    version = sources.version;

    src = super.fetchurl {
      url = "https://github.com/ollama/ollama/releases/download/v${sources.version}/ollama-linux-amd64.tar.zst";
      hash = sources.hashes.x86_64-linux;
    };

    nativeBuildInputs = with super; [ autoPatchelfHook zstd ];

    # libstdc++/libgcc_s for every binary in here; libvulkan for the Vulkan ggml
    # backend that ships next to the CUDA one and is unused on this host.
    buildInputs = [ super.stdenv.cc.cc.lib super.vulkan-loader ];

    # libcuda.so.1 is the driver, which never lives in the store. On artemis it
    # is found through LD_LIBRARY_PATH=/usr/lib/wsl/lib, set on the unit in
    # hosts/wsl.nix. cuBLAS/cudart are bundled in lib/ollama/cuda_v1*.
    autoPatchelfIgnoreMissingDeps = [ "libcuda.so.1" ];

    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;

    unpackPhase = ''
      runHook preUnpack
      mkdir -p source
      tar --use-compress-program=unzstd -xf $src -C source
      cd source
      runHook postUnpack
    '';

    # bin/ollama carries no rpath and no wrapper: it locates its backends by
    # resolving ../lib/ollama against its own executable path, so the tarball's
    # layout has to be reproduced verbatim under $out.
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r bin lib $out/
      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      $out/bin/ollama --version
    '';

    meta = with super.lib; {
      description = "Run LLMs locally — upstream Linux build, CUDA backends bundled";
      homepage = "https://ollama.com";
      license = licenses.mit;
      mainProgram = "ollama";
      platforms = [ "x86_64-linux" ];
    };
  };
}
