{ config, lib, pkgs, ... }:

# Local LLM stack for ariane -- Metal-enabled MLX from PyPI, served by
# vllm-mlx.
#
# WHY NOT NIXPKGS: nixpkgs builds python3Packages.mlx with
# -DMLX_BUILD_METAL:BOOL=FALSE, because Nix's build sandbox cannot reach
# Apple's closed-source `metal` compiler. The result imports fine and reports
# Device(cpu, 0) -- it works, silently, on the wrong processor. nixpkgs'
# `ollama` is built with OLLAMA_MLX_BACKENDS="" for the same reason and ships
# only llama-server in $out/lib/ollama. Neither can do MLX on Metal. Apple's
# PyPI wheels can, and `mlx-metal` is the separate wheel that carries it.
#
# THE TRADEOFF: this leaves pure Nix. The venv is materialized by uv and will
# not rebuild from the flake. What stays declarative is the specification --
# llm-requirements.txt is compiled, committed, and `llm sync` reproduces the
# venv from it exactly. `llm doctor` reports drift between the two.
#
# Darwin-only by construction: MLX is Metal.
let
  venv = "$HOME/.local/share/mlx-venv";
  reqIn = ./llm-requirements.in;
  reqLock = ./llm-requirements.txt;

  llm = pkgs.writeShellScriptBin "llm" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath (with pkgs; [ uv curl coreutils jq gnugrep ])}:$PATH"

    VENV="${venv}"
    LOCK=${reqLock}
    REQ_IN=${reqIn}

    sync_venv() {
      if [ ! -x "$VENV/bin/python" ]; then
        echo "creating venv at $VENV" >&2
        mkdir -p "$(dirname "$VENV")"
        uv venv --python 3.12 "$VENV"
      fi
      echo "syncing from $LOCK" >&2
      VIRTUAL_ENV="$VENV" uv pip sync --python "$VENV/bin/python" "$LOCK"
      echo "venv ready" >&2
    }

    case "''${1-}" in
      sync) sync_venv ;;
      lock)
        # Recompile the lock from the .in file. Writes to the repo, so it
        # deliberately requires being run from a checkout.
        out="''${2-}"
        if [ -z "$out" ]; then
          echo "usage: llm lock <path-to-llm-requirements.txt>" >&2
          echo "  e.g. llm lock ~/nixosdotfiles/home/llm-requirements.txt" >&2
          exit 1
        fi
        uv pip compile --python-version 3.12 "$REQ_IN" -o "$out"
        ;;
      doctor)
        if [ ! -x "$VENV/bin/python" ]; then
          echo "venv missing -- run: llm sync" >&2
          exit 1
        fi
        echo "venv:   $VENV"
        echo "python: $("$VENV/bin/python" --version 2>&1)"
        "$VENV/bin/python" - <<'PY'
import mlx.core as mx
print("device:", mx.default_device())
print("metal: ", mx.metal.is_available())
info = mx.device_info()
print("gpu:   ", info.get("device_name"))
print("budget:", round(info.get("max_recommended_working_set_size", 0) / 2**30, 1), "GiB")
PY
        ;;
      *)
        cat >&2 <<'USAGE'
    usage: llm <command>

      sync     build/update the MLX venv from the committed lockfile
      lock     recompile the lockfile from llm-requirements.in
      doctor   report venv health and whether MLX has the GPU
USAGE
        exit 1
        ;;
    esac
  '';
in
{
  # uv is the only thing Nix installs for the MLX side. Everything else lives
  # in the venv, by design -- see the header comment.
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.uv
    llm
  ];
}
