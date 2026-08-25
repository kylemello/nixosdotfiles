{ config, lib, pkgs, ... }:

# Local LLM stack for ariane -- Metal-enabled MLX from PyPI, served by
# vllm-mlx, driven by OpenCode.
#
# WHY NOT NIXPKGS: nixpkgs builds python3Packages.mlx with
# -DMLX_BUILD_METAL:BOOL=FALSE, because Nix's build sandbox cannot reach
# Apple's closed-source `metal` compiler. The result imports fine and reports
# Device(cpu, 0) -- it works, silently, on the wrong processor. nixpkgs'
# `ollama` is built with OLLAMA_MLX_BACKENDS="" for the same reason and ships
# only llama-server in $out/lib/ollama. Neither can do MLX on Metal. Apple's
# PyPI wheels can, and `mlx-metal` is the separate wheel that carries it.
#
# (llama-cpp below is the exception that proves the rule: it JIT-compiles its
# Metal shaders at runtime rather than at build time, so it sidesteps the
# sandbox entirely and nixpkgs ships it with GGML_METAL:BOOL=TRUE.)
#
# THE TRADEOFF: this leaves pure Nix. The venv is materialized by uv and will
# not rebuild from the flake. What stays declarative is the specification --
# llm-requirements.txt is compiled WITH HASHES, committed, and `llm sync`
# reproduces the venv from it exactly (--require-hashes pins artifacts, not
# merely versions). `llm doctor` reports GPU health.
#
# Darwin-only by construction: MLX is Metal.
let
  venv = "$HOME/.local/share/mlx-venv";
  reqIn = ./llm-requirements.in;
  reqLock = ./llm-requirements.txt;

  port = "8000";
  keyFile = "$HOME/.config/mlx/api-key";
  logFile = "\${XDG_STATE_HOME:-$HOME/.local/state}/mlx/server.log";

  # Three models, one loaded at a time -- ~16-19 GiB of weights each against a
  # 37.4 GiB GPU working set, so two will not co-reside. Parsers and the --mllm
  # flag below are MEASURED, not guessed: every one was verified to return
  # finish_reason="tool_calls" with correct arguments on 2026-08-24.
  coderRepo = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit";
  coderParser = "qwen3_coder";   # purpose-built parser; measured 88.0 tok/s

  # Replaced Muse Glimmer, which was dense and measured 15.4 tok/s against this
  # model's 59.4 -- a 3.9x gain from MoE (~3B active of 35B). It also drops
  # Glimmer's harmony-format chat template, for which vllm-mlx has no matching
  # parser, in favour of plain ChatML and the stock `qwen` parser.
  agentRepo = "mlx-community/Qwen3.6-35B-A3B-4bit";
  agentParser = "qwen";
  # Qwen3_5MoeForConditionalGeneration with a vision_config -- a real VLM
  # (the server logs a native video pipeline on load). vllm-mlx needs --mllm
  # to load it. The other two are plain LLMs and must NOT get it.
  agentMllm = true;

  # Dense 27B: the quality ceiling, not the speed path. Measured 14.7 tok/s,
  # which is ~75% of the 273 GB/s memory-bandwidth ceiling for ~14 GiB of
  # weights -- that is physics, not a misconfiguration. Deliberately a THIRD
  # model rather than a replacement, because the coder slot's job is cheap
  # bulk work and a dense model cannot do that.
  hardRepo = "mlx-community/Qwen3.8-27B-4bit";
  hardParser = "qwen";

  llm = pkgs.writeShellScriptBin "llm" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath (with pkgs; [ uv curl coreutils jq llama-cpp ])}:$PATH"

    VENV="${venv}"
    LOCK="${reqLock}"
    REQ_IN="${reqIn}"
    KEYFILE="${keyFile}"
    PORT="${port}"
    LOGFILE="${logFile}"

    sync_venv() {
      if [ ! -x "$VENV/bin/python" ]; then
        echo "creating venv at $VENV" >&2
        mkdir -p "$(dirname "$VENV")"
        uv venv --python 3.12 "$VENV"
      fi
      echo "syncing from $LOCK" >&2
      # --require-hashes: the lockfile is compiled with --generate-hashes, so
      # this pins artifacts and not merely versions. A yanked-and-republished
      # wheel then fails loudly instead of silently changing the venv.
      VIRTUAL_ENV="$VENV" uv pip sync --require-hashes --python "$VENV/bin/python" "$LOCK"
      echo "venv ready" >&2
    }

    # SIGTERM on a process holding 16-19 GiB of wired GPU memory against a
    # 37.4 GiB budget does not always release inside a fixed sleep. Poll, then
    # escalate -- otherwise `llm coder` straight after `llm hard` allocates on
    # top of the outgoing process and hits memory pressure.
    evict_server() {
      /usr/bin/pkill -f 'vllm-mlx serve' 2>/dev/null || true
      for _ in $(seq 30); do
        /usr/bin/pgrep -f 'vllm-mlx serve' >/dev/null 2>&1 || return 0
        sleep 1
      done
      /usr/bin/pkill -9 -f 'vllm-mlx serve' 2>/dev/null || true
      sleep 2
    }

    require_key() {
      if [ ! -f "$KEYFILE" ]; then
        echo "no API key at $KEYFILE -- create one with:" >&2
        echo "  mkdir -p ~/.config/mlx && (umask 077; openssl rand -hex 32 > $KEYFILE)" >&2
        exit 1
      fi
    }

    # Already up with the wanted model? No-op rather than restart -- reloading
    # 16-19 GiB to answer a question a curl already answered is a wasted minute.
    already_serving() {
      local repo="$1"
      [ -f "$KEYFILE" ] || return 1
      curl -sf --max-time 2 -H "Authorization: Bearer $(cat "$KEYFILE")" \
        "http://127.0.0.1:$PORT/v1/models" 2>/dev/null \
        | jq -e --arg r "$repo" 'any(.data[]?; .id == $r)' >/dev/null 2>&1
    }

    wait_ready() {
      local i
      for i in $(seq 1 150); do
        sleep 2
        curl -sf --max-time 2 -H "Authorization: Bearer $(cat "$KEYFILE")" \
          "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && return 0
        # Bail early if it died, rather than burning the full five minutes.
        /usr/bin/pgrep -f 'vllm-mlx serve' >/dev/null 2>&1 || return 1
      done
      return 1
    }

    serve_model() {
      local repo="$1" parser="$2" extra="''${3-}"
      require_key
      if [ ! -x "$VENV/bin/vllm-mlx" ]; then
        echo "venv missing -- run: llm sync" >&2
        exit 1
      fi

      if already_serving "$repo"; then
        echo "$repo already serving on http://127.0.0.1:$PORT" >&2
        return 0
      fi
      # Only one model fits at a time. Evict whatever is running first.
      # /usr/bin/pkill by absolute path, NOT via makeBinPath: nixpkgs' `procps`
      # is Linux-only (meta.platforms has no darwin), so adding it would fail
      # the build on the one machine this module targets. macOS ships pkill and
      # this module is darwin-gated.
      evict_server
      echo "serving $repo (parser: $parser) on 127.0.0.1:$PORT" >&2
      #
      # --continuous-batching is LOAD-BEARING and its own --help lies about it.
      # It reads "for multiple concurrent users (slower for single user)", but
      # the prefix cache is only constructed in batched mode. Measured on an 8K
      # repeated prefix, 2026-08-24:
      #     without it:  11.34s / 10.97s / 10.98s   (no caching whatsoever)
      #     with it:     13.56s / 11.90s /  0.42s   (28x on a cache hit)
      # In simple mode /v1/cache/stats reports all zeros and every request
      # re-prefills -- which for an agent loop means re-reading the whole
      # transcript on every single tool call. Do not remove this flag.
      #
      # --enable-prefix-cache is already the default; passed explicitly so the
      # intent survives a future default change.
      # HF_HUB_OFFLINE=1, NOT vllm-mlx's own --offline. Measured 2026-08-24:
      # --offline fails to resolve models that are present in the HF cache --
      #   RuntimeError: Model '...' not found in local cache.
      # even though the same model serves fine without it. HF_HUB_OFFLINE is
      # huggingface_hub's canonical switch, is honoured correctly, and is the
      # PHI guarantee that no weight fetch happens during inference.
      export HF_HUB_OFFLINE=1

      # DETACHED BY DEFAULT. The point of this command is to hand back a usable
      # prompt so the next thing you type can be `opencode`. An exec'd server
      # that owns the terminal makes that awkward for no benefit.
      # `llm <slot> --foreground` keeps it attached for debugging.
      set -- "$VENV/bin/vllm-mlx" serve "$repo" \
        --host 127.0.0.1 --port "$PORT" \
        --api-key "$(cat "$KEYFILE")" \
        --enable-prefix-cache --continuous-batching \
        --kv-cache-quantization --kv-cache-quantization-bits 4 \
        --enable-auto-tool-choice --tool-call-parser "$parser" \
        ''${extra:+$extra}

      if [ "$FOREGROUND" = "1" ]; then
        exec "$@"
      fi

      mkdir -p "$(dirname "$LOGFILE")"
      nohup "$@" > "$LOGFILE" 2>&1 &
      disown 2>/dev/null || true

      if wait_ready; then
        echo "ready: $repo" >&2
        echo "  endpoint  http://127.0.0.1:$PORT" >&2
        echo "  opencode  opencode run --model mlx/$repo \"...\"" >&2
        echo "  logs      llm logs        stop: llm stop" >&2
        return 0
      fi
      echo "server did not come up. tail of $LOGFILE:" >&2
      tail -15 "$LOGFILE" >&2
      return 1
    }

    # Strip --foreground/-F from anywhere in argv before dispatch.
    FOREGROUND=0
    ARGS=()
    for a in "$@"; do
      case "$a" in
        --foreground|-F) FOREGROUND=1 ;;
        *) ARGS+=("$a") ;;
      esac
    done
    set -- "''${ARGS[@]+"''${ARGS[@]}"}"

    case "''${1-}" in
      sync) sync_venv ;;
      lock)
        out="''${2-}"
        if [ -z "$out" ]; then
          echo "usage: llm lock <path-to-llm-requirements.txt>" >&2
          echo "  e.g. llm lock ~/nixosdotfiles/home/llm-requirements.txt" >&2
          exit 1
        fi
        uv pip compile --generate-hashes --python-version 3.12 "$REQ_IN" -o "$out"
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

      coder) serve_model ${lib.escapeShellArg coderRepo} ${lib.escapeShellArg coderParser} "" ;;
      agent) serve_model ${lib.escapeShellArg agentRepo} ${lib.escapeShellArg agentParser} ${lib.escapeShellArg (if agentMllm then "--mllm" else "")} ;;
      # --reasoning-parser qwen3: Qwen3.8 has a thinking mode, and without this
      # its <think> monologue leaks into message.content -- observed in an
      # OpenCode session, where the reply arrived wrapped in stray </think>
      # tags. With it, reasoning is split into message.reasoning_content and
      # content holds just the answer. The other two models have no thinking
      # mode and must not get it.
      hard)  serve_model ${lib.escapeShellArg hardRepo}  ${lib.escapeShellArg hardParser}  "--reasoning-parser qwen3" ;;

      status)
        if [ -f "$KEYFILE" ] && curl -sf --max-time 2 \
             -H "Authorization: Bearer $(cat "$KEYFILE")" \
             "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
          curl -s -H "Authorization: Bearer $(cat "$KEYFILE")" \
            "http://127.0.0.1:$PORT/v1/models" | jq -r '.data[].id'
          echo "--- prefix cache ---"
          curl -s -H "Authorization: Bearer $(cat "$KEYFILE")" \
            "http://127.0.0.1:$PORT/v1/cache/stats" \
            | jq -c '.engine_cache // "no stats"' 2>/dev/null || true
        else
          echo "vllm-mlx not running"
        fi
        ;;

      logs)
        [ -f "$LOGFILE" ] || { echo "no log at $LOGFILE" >&2; exit 1; }
        tail -f "$LOGFILE"
        ;;

      stop)
        # Idempotent by contract: nothing running is the normal state after a
        # reboot, and tests/llm.test.sh asserts exit 0 in that case.
        evict_server
        echo "stopped" >&2
        ;;

      long)
        # Escape hatch for prompts past roughly 60K tokens. NOTE: no GGUF is
        # downloaded by this setup -- the three models above are MLX
        # safetensors, which llama.cpp cannot read. Fetch a GGUF yourself.
        #
        # Also be warned: llama.cpp's support for the "qwen3_5" hybrid
        # architecture used by Qwen3.6-35B-A3B and Qwen3.8-27B had open
        # conversion/inference correctness bugs as of 2026-08-22. Verify output
        # sanity before trusting this path for those two model families.
        gguf="''${2-}"
        if [ -z "$gguf" ] || [ ! -f "$gguf" ]; then
          echo "usage: llm long <path-to.gguf>" >&2
          exit 1
        fi
        require_key
        evict_server
        # --api-key-file, not --api-key: llama-server supports reading the key
        # from a file, which keeps it out of the process table. vllm-mlx has no
        # equivalent and takes it in argv -- see the PHI note in docs/local-llm.md.
        #
        # `--flash-attn on`, not bare `--flash-attn`: as of build 10408 the flag
        # takes an [on|off|auto] value and a bare form swallows the NEXT
        # argument, failing with
        #   error: unknown value for --flash-attn: '--n-gpu-layers'
        exec llama-server \
          --model "$gguf" \
          --host 127.0.0.1 --port 8080 \
          --api-key-file "$KEYFILE" \
          --ctx-size 131072 \
          --flash-attn on \
          --n-gpu-layers 99 \
          --jinja
        ;;

      *)
        cat >&2 <<'USAGE'
usage: llm <command>

  serving (one model at a time -- ~16-19 GiB each, 37.4 GiB budget)
    coder    Qwen3-Coder-30B-A3B  fast bulk work, completions   ~88 tok/s
    agent    Qwen3.6-35B-A3B      tool use, agentic loops       ~59 tok/s
    hard     Qwen3.8-27B          best quality, thinking mode   ~15 tok/s
    long     <file.gguf>          llama.cpp, for >60K prompts

  Serving commands DETACH and return once the model answers, so the next
  thing you type can be opencode. Add --foreground/-F to keep one attached.

  lifecycle
    status   what is loaded, plus prefix-cache hit stats
    logs     follow the server log
    stop     tear down the server and free the memory

  venv
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
  # uv drives the MLX venv; llama-cpp is the long-context escape hatch and is
  # the one inference engine nixpkgs CAN build with Metal. Everything else
  # lives in the venv, by design -- see the header comment.
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.uv
    pkgs.llama-cpp
    llm
  ];

  # OpenCode -> local vllm-mlx. The API key file (~/.config/mlx/api-key, mode
  # 0600) is never read by Nix and never touches the store: `{file:...}` is an
  # OpenCode-side placeholder resolved at runtime, so only this literal string
  # -- not the key -- lands in the store-backed config. That matters because
  # store paths are world-readable and this repo is public.
  #
  # `provider` deliberately contains exactly ONE entry. Every PHI guarantee in
  # the design reduces to that fact plus the loopback baseURL: with no cloud
  # provider configured, there is nothing for OpenCode to fall back to.
  #
  # Model ids contain slashes, which is fine: OpenCode's --model parser splits
  # on the FIRST slash only and passes the remainder through verbatim, so
  # `mlx/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` resolves correctly.
  xdg.configFile."opencode/opencode.json" = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";

      # Session transcripts must never leave this machine. This is the real
      # egress risk in OpenCode -- there is no separate telemetry SDK.
      share = "disabled";
      # Belt and braces: the nixpkgs opencode wrapper already hardcodes
      # OPENCODE_DISABLE_AUTOUPDATE=true, but a future wrapper change should
      # not silently re-enable it.
      autoupdate = false;

      provider.mlx = {
        npm = "@ai-sdk/openai-compatible";
        name = "MLX (local, vllm-mlx)";
        options = {
          baseURL = "http://127.0.0.1:${port}/v1";
          apiKey = "{file:~/.config/mlx/api-key}";
        };
        models = {
          "${coderRepo}" = { name = "Qwen3-Coder 30B A3B — fast coding"; tools = true; };
          "${agentRepo}" = { name = "Qwen3.6 35B-A3B — agentic"; tools = true; };
          # Qwen3.8 has a thinking mode; the server reports it and offers
          # --reasoning-parser qwen3 to surface it separately. Not enabled on
          # the server yet, so this only advertises the capability.
          "${hardRepo}" = { name = "Qwen3.8 27B — hard problems"; tools = true; reasoning = true; };
        };
      };
    };
  };
}
