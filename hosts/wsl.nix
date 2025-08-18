{ config, pkgs, lib, ... }:

{
  # Enable core WSL integration.
  wsl = {
    enable = true;
    defaultUser = "kyle";
    useWindowsDriver = true;
  };

  services.openssh.enable = false;

  nixpkgs.config.allowUnfree = true;

  # Environment so CUDA/NVIDIA libs are visible
  environment.sessionVariables = {
    CUDA_PATH = "${pkgs.cudatoolkit}";
    EXTRA_LDFLAGS = "-L/lib -L${pkgs.linuxPackages.nvidia_x11}/lib";
    EXTRA_CCFLAGS = "-I/usr/include";
    LD_LIBRARY_PATH = "${pkgs.linuxPackages.nvidia_x11}/lib:/usr/lib/wsl/lib";
    MESA_D3D12_DEFAULT_ADAPTER_NAME = "Nvidia";
    CONTAINER_CDI_SPEC_DIRS = "/etc/cdi";
  };

  hardware = {
    nvidia = {
      modesetting.enable = true;
      nvidiaSettings = true;
      open = true;
    };
    nvidia-container-toolkit = {
      enable = true;
      mount-nvidia-executables = false;
    };
  };

  systemd.services.nvidia-cdi-generator = {
    description = "Generate NVIDIA CDI spec";
    wantedBy = [ "podman.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.nvidia-docker}/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml --nvidia-ctk-path=${pkgs.nvidia-container-toolkit}/bin/nvidia-ctk";
    };
  };

  virtualisation.podman = {
    extraPackages = [ pkgs.crun pkgs.podman-compose ];
  };

  services.xserver.videoDrivers = ["nvidia"];
}
