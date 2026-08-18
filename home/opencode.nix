{ config, lib, pkgs, ... }:

# opencode's provider config, pointing it at the ollama server that
# hosts/wsl.nix runs on this machine.
#
# Unlike home/claude.nix and home/nvim.nix this does NOT symlink an editable
# tree out of the repo. Those exist so the tool's own edits land in git;
# opencode needs no such thing here, and this repo is public, so a plain
# read-only store symlink is both sufficient and safer. Everything opencode
# writes for itself — auth.json, sessions, and the provider npm package it
# resolves into ~/.config/opencode/node_modules — lives outside this file and
# is left unmanaged.
let
  cfg = config.kyle.opencode;
in
{
  options.kyle.opencode = {
    enable = lib.mkEnableOption ''
      ~/.config/opencode/opencode.json declaring the local ollama provider.

      Off by default and enabled per-host in home/wsl.nix, NOT in
      users/kyle/home.nix — that profile is imported by all four NixOS hosts
      and only artemis runs ollama. ariane has no NVIDIA GPU either, so it
      deliberately gets nothing from this module
    '';

    baseURL = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:11434/v1";
      description = ''
        ollama's OpenAI-compatible endpoint. Loopback on purpose — the server
        is unauthenticated, and services.ollama.host defaults to 127.0.0.1.
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "kat-coder";
      description = ''
        ollama tag to expose, as `ollama list` prints it. Kept short on
        purpose: opencode addresses a model as `<provider>/<model>`, so
        pointing this straight at a pulled `hf.co/owner/repo:QUANT` id would
        bury slashes and a colon inside that reference. See hosts/wsl.nix for
        how the short tag is produced.
      '';
      example = "kat-coder";
    };

    contextLimit = lib.mkOption {
      type = lib.types.int;
      default = 65536;
      description = ''
        Must not exceed OLLAMA_CONTEXT_LENGTH in hosts/wsl.nix. ollama
        silently truncates a longer prompt to the server's window, so a
        mismatch here shows up as the model quietly forgetting the start of a
        long file rather than as an error.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."opencode/opencode.json".text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      provider.ollama = {
        # opencode resolves this npm package at runtime into
        # ~/.config/opencode/node_modules; it is the generic OpenAI-compatible
        # adapter, which is what ollama's /v1 endpoint speaks.
        npm = "@ai-sdk/openai-compatible";
        name = "ollama (local)";
        options.baseURL = cfg.baseURL;
        models.${cfg.model} = {
          name = "KAT-Coder V2.5 abliterated (local)";
          tool_call = true;
          limit = {
            context = cfg.contextLimit;
            output = 32768;
          };
        };
      };
    };
  };
}
