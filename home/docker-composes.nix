{ config, lib, ... }:

# The compose definitions in ../docker-composes, linked to ~/docker-composes.
#
# Nix manages the DEFINITIONS and nothing else: no systemd unit, no container at
# boot, no engine configuration. Stacks are started by hand, from the folder,
# which is how the dev databases on this machine have always been run:
#
#   cd ~/docker-composes/postgres && docker compose up -d
#
# `recursive = true` links every file individually instead of symlinking the
# directory, which is the point: a read-only store symlink over the whole tree
# would leave nowhere to put the per-stack `.env`, and those hold credentials
# this repo (public) must not carry. So each stack is a real directory holding
# managed compose files next to an unmanaged, machine-local `.env`. Compose
# defaults every variable to a dev value, so a stack still comes up with no
# `.env` present at all; `.env.example` in each folder lists what to override.
#
# Bind mounts survive the indirection — `./my.cnf` resolves through the symlink
# into /nix/store and Docker Desktop mounts it read-only without complaint
# (measured 2026-08-20 with both a symlinked path and a store path).
let
  cfg = config.kyle.dockerComposes;
in
{
  options.kyle.dockerComposes.enable = lib.mkEnableOption ''
    ~/docker-composes, the hand-run compose stacks.

    Off by default and enabled per-host in home/wsl.nix, NOT in
    users/kyle/home.nix — artemis is the machine with Docker Desktop's WSL
    integration and the ollama server the open-webui stack talks to. The other
    three NixOS hosts would get compose files for engines and services they do
    not run
  '';

  config = lib.mkIf cfg.enable {
    home.file."docker-composes" = {
      source = ../docker-composes;
      recursive = true;
    };
  };
}
