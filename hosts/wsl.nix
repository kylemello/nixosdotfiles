{ config, pkgs, lib, ... }:

{
  # Home Manager refuses to replace a pre-existing unmanaged file and fails the
  # WHOLE rebuild rather than skipping it ("Existing file ... would be
  # clobbered", check-link-targets.sh). home/claude.nix is about to take over
  # ~/.claude/{settings.json,settings.local.json,skills}, all three of which
  # already exist here by hand — note an empty directory counts, so `skills`
  # collides too. Without this, `nixos-rebuild switch --flake .#artemis` aborts.
  #
  # This lives in hosts/wsl.nix, NOT hosts/common.nix, because artemis is the
  # only NixOS host with any Home-Manager-managed dotfile collisions:
  # kyle.claude.enable is off on atlas/gateway/nixosvm, and setting the option
  # in hosts/common.nix perturbs all four systemd home-manager units (measured:
  # it changes atlas/gateway/nixosvm's system derivation hashes for no benefit).
  #
  # The backups are one-shot: a second rebuild fails if a `.hm-bak` from the
  # first is still sitting there, so clear them once the switch is confirmed.
  home-manager.backupFileExtension = "hm-bak";

  # Enable core WSL integration.
  wsl = {
    enable = true;
    docker-desktop.enable = true;
    defaultUser = "kyle";
    useWindowsDriver = true;
    interop.includePath = false;
  };

  # ---- NVIDIA GPU ---------------------------------------------------------
  # There are no /dev/nvidia* nodes here and no kernel module to load: WSL GPU
  # access goes through /dev/dxg plus the Windows driver's own libraries
  # mounted at /usr/lib/wsl/lib, so the `hardware.nvidia*` options do not apply
  # and must stay off. `useWindowsDriver` above symlinks those libraries into
  # /run/opengl-driver/lib, putting them in the RUNPATH of nixpkgs' CUDA and
  # GL packages.
  #
  # That is enough to *find* libcuda/libnvidia-ml but not to use them: those
  # libraries carry no RUNPATH of their own and dlopen libdxcore.so by bare
  # name, and DT_RUNPATH does not apply to objects a dependency loads, so the
  # dlopen fails and the card looks absent. Measured before this line: nvtop
  # reported "No GPU to monitor" and cuInit() returned 100 (NO_DEVICE); with
  # /usr/lib/wsl/lib on LD_LIBRARY_PATH both see the 5090. NixOS-WSL's
  # `wslConf.automount.ldconfig` is the upstream answer for other distros and
  # its own description says it does not work here — NixOS has neither
  # /etc/ld.so.conf.d nor /etc/ld.so.cache — so the path must come from the
  # environment.
  #
  # A global LD_LIBRARY_PATH is usually a NixOS footgun. It is tolerable here
  # because that directory holds nothing but the Windows driver's
  # libcuda/libnvidia-*/libd3d12/libdxcore — no libc, libstdc++ or anything
  # else a Nix binary could be mis-resolved against. Note it reaches login
  # shells and user services but NOT system systemd units; a GPU daemon needs
  # the same path in its own `environment`.
  environment.sessionVariables.LD_LIBRARY_PATH = [ "/usr/lib/wsl/lib" ];

  # nvidia-smi ships as a plain binary inside /usr/lib/wsl/lib, which is on no
  # PATH, and it looks for libnvidia-ml.so.1 beside itself rather than through
  # the driver path — unwrapped it exits with "NVIDIA-SMI couldn't find
  # libnvidia-ml.so". It sets the path itself so it also works from systemd
  # units, which never source the session variables above. makeWrapper cannot
  # be used: it asserts its target exists at build time, and /usr/lib/wsl/lib
  # is a host runtime path absent from the build sandbox.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "nvidia-smi" ''
      exec env LD_LIBRARY_PATH="/usr/lib/wsl/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        /usr/lib/wsl/lib/nvidia-smi "$@"
    '')
  ];

  # Local coding model on the card. ollama-cuda is NOT on cache.nixos.org —
  # nixpkgs does not redistribute binaries built against the CUDA toolkit — so
  # this was built locally: `nix build --dry-run` reported 18 derivations to
  # build and nothing substitutable.
  #
  # `services.ollama.acceleration` is retired in this nixpkgs and setting it is
  # a hard eval error, so the package is named directly instead.
  #
  # Models live on the Windows D: drive, not in the WSL VHD. C: is down to
  # 108 GB free and the VHD grows out of it, while D: has 2.7 TB. The cost is
  # throughput: /mnt/d is a 9p mount and measures 130 MB/s sequential (vs
  # ~GB/s on the VHD), so a cold load of the 21 GB Q4_K_M weights takes about
  # 2.7 minutes. OLLAMA_KEEP_ALIVE below is what makes that acceptable — the
  # model is loaded once and pinned in VRAM rather than re-read after every
  # idle timeout.
  #
  # The directory must be world-writable (it is, mode 0777): the unit runs
  # under DynamicUser, so its uid is not kyle's, and /mnt/d is mounted
  # uid=1000 with `metadata` so real mode bits are enforced. `user`/`group`
  # are deliberately NOT set to kyle — the module would then declare
  # users.users.kyle with isSystemUser, colliding with the real account.
  # modelsDir is added to the unit's ReadWritePaths by the module itself,
  # which matters under its ProtectSystem=strict.
  #
  # Importing the model is a manual step. `ollama pull hf.co/<repo>:Q4_K_M`
  # does NOT work for this repo — measured: it returns
  # `400 The specified tag is not available in the repository`, because the
  # files are named with the quant as a prefix (Q4_K_M-KAT-Coder-....gguf)
  # rather than the suffix ollama's resolver expects. Download the .gguf from
  # HuggingFace and `ollama create kat-coder -f Modelfile` against it instead.
  # `kat-coder` is the short tag home/opencode.nix points opencode at.
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
    modelsDir = "/mnt/d/AI/ollama/models";

    environmentVariables = {
      # sessionVariables above do not reach system units, and without this
      # ollama finds no device — same libdxcore dlopen reason as everything
      # else in this section.
      LD_LIBRARY_PATH = "/usr/lib/wsl/lib";

      # ollama's default window is 4096 tokens, which is useless for coding.
      # Budget against 32 GB of VRAM: Q4_K_M weights are 21.1 GB, and this
      # model (Qwen3.6-35B-A3B shape — 48 layers, 4 KV heads, 128 head dims)
      # costs ~96 KB/token of KV cache at f16, so 64k tokens would be 6.3 GB.
      # q8_0 halves that to ~3.1 GB and puts the total near 24 GB with room
      # for the compute buffers. Quantized KV needs flash attention, hence the
      # third variable. Keep kyle.opencode.contextLimit in step with this.
      OLLAMA_CONTEXT_LENGTH = "65536";
      OLLAMA_KV_CACHE_TYPE = "q8_0";
      OLLAMA_FLASH_ATTENTION = "1";

      # Never evict. Without this ollama unloads after 5 minutes idle and the
      # next request pays the 2.7-minute reload across 9p described above.
      # The 5090 has nothing else competing for its VRAM.
      OLLAMA_KEEP_ALIVE = "-1";
    };
  };

  # ---- SSH into the WSL instance ------------------------------------------
  # WSL runs with `networkingMode=mirrored` (set Windows-side in
  # %USERPROFILE%\.wslconfig), so the distro shares the host's network
  # interfaces instead of sitting behind a NAT. Two consequences:
  #
  #   * Windows' own OpenSSH server already listens on :22, and in mirrored
  #     mode the host wins that port — so sshd here must use a different one
  #     or it silently never receives a connection.
  #   * Binding 0.0.0.0 is enough to be reachable at the host's LAN and
  #     Tailscale addresses; no `netsh interface portproxy` forwarding needed
  #     (that is only required for the default NAT mode).
  #
  # Windows still gates inbound traffic to the WSL vSwitch behind the Hyper-V
  # firewall, which defaults to DefaultInboundAction=Block. Opening the port
  # below is necessary but NOT sufficient — the host-side rules are imperative
  # and live outside Nix. To (re)apply them, in an elevated PowerShell:
  #
  #   New-NetFirewallHyperVRule -Name WSL-SSH -DisplayName 'WSL SSH' `
  #     -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' `
  #     -Protocol TCP -LocalPorts 2222 -Action Allow
  #   New-NetFirewallRule -DisplayName 'WSL SSH' -Direction Inbound `
  #     -Protocol TCP -LocalPort 2222 -Action Allow -Profile Private,Domain
  services.openssh = {
    enable = true;
    ports = [ 2222 ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  networking.firewall.allowedTCPPorts = [ 2222 ];

  services.pulseaudio.enable = true;
  networking.wireless.enable = lib.mkForce false;

  nixpkgs.config.allowUnfree = true;

  environment.unixODBCDrivers = [ pkgs.unixodbcDrivers.msodbcsql18 ];
}
