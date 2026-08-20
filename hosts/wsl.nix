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

    # Raise the 9p transport's max message size from WSL's 64 KB default to the
    # 256 KB it actually caps at (asking for 1 MB just gets clamped — measured,
    # the mount reports msize=262144). This is the single biggest cheap win
    # available for /mnt/d, which every model in services.ollama below is read
    # from: benchmarked 2026-08-18 on the same 4 GiB GGUF with the page cache
    # dropped between runs, 134 MB/s at 64 KB versus 398 MB/s at 256 KB — 3x,
    # for one mount option.
    #
    # It matters because ollama mmaps model weights (`load_mode = mmap` in its
    # logs) rather than reading them sequentially, so a cold load is a long
    # storm of demand-paged round trips and 9p latency per message dominates.
    # Bigger messages mean proportionally fewer of them.
    #
    # This is automount-wide, so /mnt/c gets it too — no reason not to. NOTE it
    # only lands at WSL boot: editing wsl.conf does nothing to already-mounted
    # filesystems, so a full `wsl --shutdown` from Windows is required. The
    # fileSystems."/mnt/d" entry below carries the same option so that any
    # systemd remount (including the repair unit) uses it immediately.
    wslConf.automount.options = "metadata,uid=1000,gid=100,msize=1048576";
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

  # ---- The D: drive -------------------------------------------------------
  # /mnt/d holds ollama's model store (services.ollama.modelsDir below), and it
  # is the one automount that cannot be trusted to stay up: D: is an external
  # OWC 4M2 enclosure, so it drops off the Windows side on its own (a
  # sleep/resume, a nudged cable). When it does, the 9p channel dies for good
  # and *silently* — the mount stays in /proc/mounts looking perfectly healthy
  # while every access returns ENODEV. Measured 2026-08-18: `ls /mnt/d` gave
  # "No such device" while Windows' own Get-Volume still reported D: Healthy,
  # and ollama answered every /api/tags with a 500. WSL's automount runs once,
  # at instance boot, so nothing repairs this short of `wsl --shutdown`.
  #
  # Declaring the mount here does not change how it normally gets mounted —
  # WSL's automount still wins that race, pre-systemd, and this unit adopts
  # whatever it finds already mounted. What the declaration buys is the *name*
  # `mnt-d.mount`, which the repair unit and ollama's ordering below both hang
  # off. `nofail` keeps a genuinely detached D: from holding up local-fs.target.
  fileSystems."/mnt/d" = {
    device = "D:";
    fsType = "drvfs";
    options = [ "metadata" "uid=1000" "gid=100" "nofail" "msize=1048576" ];
    noCheck = true;
  };

  # modelsDir has to be world-writable, and was not. The ollama unit runs under
  # DynamicUser so its uid is never kyle's, and /mnt/d is mounted with
  # `metadata`, which makes the real mode bits enforceable instead of every
  # file reading as 0777. Measured 2026-08-18 with the tree at 0755: serving an
  # already-imported model worked (0755 is world-*readable*) but importing did
  # not — `ollama cp qwen3:0.6b permtest` failed with "mkdir
  # .../manifests/registry.ollama.ai/library/permtest: permission denied", and
  # succeeded after a chmod. So `ollama pull` and the `ollama create` step
  # described below were both quietly broken.
  #
  # `Z` is recursive because the failure is on a nested directory, not the top
  # one, and new model imports keep creating more of them; the tree is 7
  # directories and 10 files, so the boot-time cost over 9p is nil. It
  # deliberately is not a `d`/`D` rule: those create what is missing, which
  # would build this tree on the VHD root every time D: happened to be detached
  # and then sit in the way of the real mount. `Z` only ever adjusts a path
  # that already exists.
  systemd.tmpfiles.rules = [
    "Z /mnt/d/AI/ollama/models 0777 - - -"
  ];

  # systemd cannot notice a stale 9p mount on its own: mnt-d.mount stays
  # `active (mounted)` because the mount point is still listed in mountinfo,
  # and no amount of ordering or Restart= helps once the channel behind it is
  # dead. Only a real I/O attempt reveals it, so it takes a timer.
  #
  # ollama is restarted rather than left to notice by itself. It runs with
  # ProtectSystem=strict and ReadWritePaths=<modelsDir>, so systemd gives it a
  # private mount namespace holding a bind mount of the models directory —
  # confirmed in /proc/<pid>/mountinfo, which showed a separate mnt ns and the
  # bind sharing the host mount's 9p superblock. That bind is pinned to the
  # superblock it was made from, so a fresh mount on the host propagates in
  # *underneath* it and the process carries on reading the dead one.
  systemd.services.repair-mnt-d = {
    description = "Detect and repair a stale /mnt/d drvfs mount";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.util-linux pkgs.coreutils pkgs.systemd ];
    script = ''
      # No `set -e`: every failure below is handled explicitly, and a detached
      # D: has to exit 0 or the timer logs a failure every two minutes.
      set -u

      # findmnt answers out of mountinfo, so unlike `mountpoint` it decides
      # without touching the filesystem — which is the entire problem here.
      mounted() { findmnt --mountpoint /mnt/d >/dev/null 2>&1; }

      # `timeout`, because a half-dead 9p channel can block a stat forever.
      readable() { timeout 20 stat -t /mnt/d/. >/dev/null 2>&1; }

      # Both conditions are needed. `readable` on its own is NOT enough:
      # with the mount gone, the bare /mnt/d directory sitting on the VHD
      # underneath it stats perfectly well. Measured while writing this — a
      # readable-only check called an unmounted /mnt/d healthy and exited 0
      # without ever remounting, which is precisely the boot-time case where
      # D: attaches late. The flip side is that this unit will remount /mnt/d
      # within two minutes even if you unmounted it on purpose; stop the timer
      # first if that is what you want.
      if mounted && readable; then
        exit 0
      fi

      if mounted; then
        echo "/mnt/d is mounted but unreadable; detaching the stale mount"
        systemctl stop mnt-d.mount || umount -l /mnt/d
      fi

      if ! systemctl start mnt-d.mount; then
        echo "D: is not attached on the Windows side; leaving /mnt/d unmounted"
        exit 0
      fi

      if ! readable; then
        echo "remounted /mnt/d but it is still unreadable"
        exit 1
      fi

      # `restart`, not `try-restart`: ollama Requires= the mount, so stopping
      # it above also stopped ollama, and try-restart is a no-op on a stopped
      # unit. This is also what recovers ollama from the failed state it lands
      # in when D: was missing at boot.
      echo "/mnt/d remounted; restarting ollama to drop its stale bind mount"
      systemctl restart ollama.service
    '';
  };

  systemd.timers.repair-mnt-d = {
    description = "Periodically check /mnt/d for a stale drvfs mount";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "2min";
      AccuracySec = "30s";
    };
  };

  # Requires=, not just After=: with only ordering, ollama starts happily
  # against a missing models directory and then answers every request with a
  # 500, which is how the 2026-08-18 breakage presented. Failing to start is
  # the louder and more honest outcome, and the repair timer above brings both
  # units back within two minutes once D: returns.
  systemd.services.ollama = {
    after = [ "mnt-d.mount" ];
    requires = [ "mnt-d.mount" ];

    # Run as kyle (uid 1000) rather than under DynamicUser.
    #
    # /mnt/d is mounted uid=1000, so everything on it belongs to kyle no matter
    # who wrote it — and POSIX only lets the *owner* set an explicit mtime.
    # utimes() with concrete times is EPERM for anyone else, while the mode bits
    # only ever grant UTIME_NOW. Measured 2026-08-18 against a 0777 file on this
    # mount: kyle could `touch -d 2020-01-01`, `nobody` got "Operation not
    # permitted", and a plain `touch` (= now) worked for both. No chmod can fix
    # this, so the 0777 rule above is necessary for writes and irrelevant here.
    #
    # What it broke: `ollama create` refreshes the mtime of a blob that already
    # exists, so importing any model that SHARES a layer with an installed one
    # died on it. Measured: Qwen3.6-35B-A3B failed with `chtimes
    # .../blobs/sha256-7cfc980a...: operation not permitted` on a 160-byte
    # params layer it shares with kat-coder (identical qwen35moe 35B-A3B shape)
    # — after 16 minutes of copying, and only at the very end. gemma-3, gemma-4
    # and dolphin all imported fine because every layer of theirs was new.
    # Verified that kyle *can* retime a blob the old DynamicUser created, so
    # this needs no re-owning of the 123 GB already in the store.
    #
    # `services.ollama.user` is deliberately NOT the lever: the module would
    # then declare users.users.kyle with isSystemUser and collide with the real
    # account (the reason the option is left alone in services.ollama above).
    # Overriding the unit skips that declaration. mkForce is required because
    # the module sets DynamicUser itself.
    #
    # The tradeoff, accepted: this drops DynamicUser's uid isolation and gives
    # the daemon kyle's own uid. On a single-user box whose whole job is serving
    # kyle's models out of kyle's directory, that is a fair trade for imports
    # that actually work.
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "kyle";
      Group = "users";
    };
  };

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

  # ---- Open WebUI ---------------------------------------------------------
  # Not here. It is a compose stack, ~/docker-composes/open-webui, managed as a
  # file by home/docker-composes.nix and started by hand like the dev databases
  # next to it.
  #
  # It was a virtualisation.oci-containers container until 2026-08-20 and that
  # could not work on this host, for two reasons worth keeping:
  #
  #   * The module's default log driver is journald, and this dockerd rejects it
  #     ("journald is not enabled on this host" at container create). nixpkgs'
  #     moby carries the stub driver, so `docker info` advertises journald while
  #     nothing can initialize it — no daemon.json entry turns it on. The unit
  #     sat in start-limit-hit from its first start.
  #
  #   * `docker` in this distro is not artemis's dockerd. Docker Desktop's WSL
  #     integration re-binds /var/run/docker.sock (= /run/docker.sock) to a proxy
  #     into its own VM, replacing the file systemd's docker.socket created;
  #     artemis's dockerd keeps listening on the now-unlinked inode, running and
  #     unreachable by path. So the unit's container was created in the
  #     docker-desktop distro — /etc/hostname `docker-desktop`, `--network=host`
  #     joining that distro's namespace — where it could reach neither ollama on
  #     artemis's loopback (curl to 127.0.0.1:11434 from inside: no answer) nor
  #     a browser on :3000, from Windows or from here.
  #
  # The compose stack sidesteps both: Docker Desktop's engine is the one being
  # asked, ports are published rather than shared, and ollama is reached at
  # host.docker.internal:11434 — which means OLLAMA_HOST above stays on
  # loopback and 11434 stays off the LAN and off Tailscale.
  #
  # The old container's SQLite lives in /var/lib/open-webui (root-owned, written
  # through Docker Desktop's file sharing). It was copied into the stack's
  # named volume on 2026-08-20; the directory is left in place, unmanaged.

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
