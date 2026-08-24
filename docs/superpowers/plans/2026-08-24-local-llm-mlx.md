# Local LLM on ariane (MLX + OpenCode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **REVISION 2, 2026-08-24.** Revision 1 targeted Ollama's MLX engine and failed at Task 1: nixpkgs builds MLX with `-DMLX_BUILD_METAL:BOOL=FALSE` and Ollama with `OLLAMA_MLX_BACKENDS=""`, so neither can reach Metal. See the Amendment section of the spec. This revision uses Apple's PyPI MLX wheels in a `uv` venv, with `vllm-mlx` as the server. **Ollama is dropped.**

**Goal:** Run Qwen3-Coder-30B-A3B and Muse Glimmer 30B on ariane's GPU through `vllm-mlx`, driven by OpenCode, with llama.cpp retained as a long-context escape hatch.

**Architecture:** A `uv`-managed virtualenv at `~/.local/share/mlx-venv` supplies Metal-enabled `mlx`, `mlx-metal`, `mlx-lm`, and `vllm-mlx` from PyPI. Its contents are pinned by a lockfile committed to the repo, so the *specification* stays declarative even though the venv is materialized imperatively. A Home Manager module `home/llm.nix` provides `uv`, the lockfile, and an `llm` command that builds the venv and drives the server on demand.

**Tech Stack:** Nix flakes + standalone Home Manager, `uv` 0.12.3, MLX 0.32.1 + mlx-metal 0.32.1 (PyPI), mlx-lm 0.31.3, vllm-mlx 0.4.1, llama.cpp ≥ b10353, OpenCode 1.18.x, fish.

## Global Constraints

Every task's requirements implicitly include this section.

- **Bind loopback only (`127.0.0.1`). Never `0.0.0.0`.** vllm-mlx takes `--host`; it defaults to something else, so pass it explicitly every time.
- **Serve with `--api-key`.** vllm-mlx prints `SECURITY WARNING: Server running without API key authentication` when it is omitted. The key is generated locally, stored at `~/.config/mlx/api-key` with mode 0600, and **never committed** — the repo is public.
- **Pass `--offline` once models are downloaded.** PHI use case: the server must not reach the network during inference.
- **The OpenCode local profile carries zero cloud providers**, and `"share": "disabled"`.
- **`llama-cpp` must be ≥ b10353.** Pinned nixpkgs supplies b10273; unstable HEAD supplied b10408 on 2026-08-24.
- **`iogpu.wired_limit_mb=40960`** — needs `sudo`, does not survive reboot, cannot be Home Manager–managed. Documented, never scripted into activation. Measured ceiling without it: **37.4 GiB** max recommended working set, reported by `mx.device_info()`.
- **On-demand only. No launchd agent.**
- **Model weights and the venv live outside the Nix store** — `~/.cache/huggingface` and `~/.local/share/mlx-venv`.
- **The working tree has pre-existing unrelated changes**: `claude/local/ariane.json`, `claude/settings.json`, `nvim/lazy-lock.json`, and a deliberately-staged `flake.lock` input bump. Stage explicit paths. **Never `git add -A`, never `git commit -a`.**
- **New files must be `git add`ed before any `nix` eval or switch reads them.** Per `CLAUDE.md`: flakes only see git-tracked files.
- **This repo is PUBLIC** (`github.com/kylemello/nixosdotfiles`).
- **Repo convention:** use `writeShellScriptBin`, never `writeShellApplication` (it pulls shellcheck, a heavy uncached Haskell build).
- **Every speed number in the spec is third-party.** No task may cite one as an observed result.

**Commands used throughout:**

```bash
cd ~/nixosdotfiles
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
home-manager switch --flake .#ariane -b backup
```

## Verified environment facts — do not re-derive

Measured on ariane 2026-08-24. Trust these; re-deriving them wastes a task.

- PyPI MLX **works on Metal**: `default_device: Device(gpu, 0)`, `metal available: True`, `device: Apple M4 Pro`, `max recommended working set: 37.4 GiB`, `memory size: 48.0 GiB`.
- `mlx-metal` is a **separate wheel** from `mlx`. Installing `mlx` alone on macOS pulls it, but pin both.
- `uv` 0.12.3 is already on PATH from `~/.nix-profile`.
- Resolved wheel versions: `mlx` 0.32.1, `mlx-metal` 0.32.1, `mlx-lm` 0.31.3, `vllm-mlx` 0.4.1. `vllm-mlx` also pulls `mlx-vlm` 0.6.15, `mlx-audio` 0.5.0, `mlx-embeddings` 0.1.0.
- A full venv with all of the above is **~1.3 GB**.
- `vllm-mlx serve` works, binds `127.0.0.1`, and was ready in **~26 s** on a 1B model.
- Routes confirmed live: `/v1/chat/completions`, `/v1/completions`, `/v1/models`, **`/v1/messages` (Anthropic, HTTP 200)**, `/v1/cache/stats`, `/v1/cache/prefix`, `/v1/mcp/{tools,servers,execute}`, `/v1/embeddings`, `/v1/rerank`, `/health`, `/metrics`.
- `/v1/cache/stats` returns real counters: `hits`, `misses`, `stores`, `evictions`, `hit_ratio`.
- `--tool-call-parser` accepts: `auto, mistral, qwen, qwen3_coder, llama, hermes, harmony, gpt-oss, deepseek, kimi, granite, nemotron, xlam, functionary, gemma4, glm47, minimax`. There is no `muse` parser, but **Task 2 established that Muse Glimmer's chat template is harmony-format** — it emits `<|start|>`, `<|message|>`, `<|eom|>`, `<|eot|>` and `to=self` / `to=example` recipients. So `harmony` is the evidence-based first choice, not `auto`.
- **Muse Glimmer is a vision-language model**: `architectures: ["MuseGlimmerForConditionalGeneration"]`, `model_type: muse_glimmer`, `vision_config` present. `mlx_lm` cannot load it (`Model type muse_glimmer not supported`); `mlx_vlm` can. **vllm-mlx needs `--mllm` to serve it.** The coding model is a plain LLM and must NOT get `--mllm`.
- Measured on ariane in Task 2 — these are real, not third-party: coder `mlx_lm.generate` prompt 12.211 tok/s, generation **88.048** tok/s, peak 17.250 GB. Agentic `mlx_vlm.generate` prompt 47.577 tok/s, generation **15.123** tok/s, peak 19.646 GB. The coder figure is well below the ~130 tok/s the spec cites from a blog.
- Ollama and the CPU-only nixpkgs `mlx` are **currently installed** by Home Manager generation 28 from the failed Revision 1. Task 1 removes them.

---

### Task 1: Metal-capable MLX venv, pinned and proven on the GPU

Replaces Revision 1's Task 1 entirely. The staged-but-uncommitted `home/llm.nix` and `tests/llm.test.sh` from that attempt are **wrong for this design** — overwrite them.

**Files:**
- Overwrite: `home/llm.nix` (currently staged with the dead Ollama design)
- Overwrite: `tests/llm.test.sh` (same)
- Create: `home/llm-requirements.in`
- Create: `home/llm-requirements.txt` (generated, committed)
- Already modified: `users/kyle/ariane.nix` (the `../../home/llm.nix` import is already in place from Revision 1 — verify, don't duplicate)

**Interfaces:**
- Consumes: nothing.
- Produces: venv at `~/.local/share/mlx-venv` with `bin/python`, `bin/mlx_lm.generate`, `bin/vllm-mlx`. An `llm` command on PATH whose only implemented subcommand this task is `llm sync`. Test helpers `ok`, `bad`, `check`, `have` and the variable `VENV=$HOME/.local/share/mlx-venv` in `tests/llm.test.sh`.

- [ ] **Step 1: Write the pinned requirements input**

Create `home/llm-requirements.in`:

```
# Top-level pins for the MLX stack. Compiled to llm-requirements.txt by
# `uv pip compile` (see home/llm.nix, `llm lock`).
#
# These come from PyPI, NOT nixpkgs, and that is the whole point: nixpkgs
# builds mlx with -DMLX_BUILD_METAL:BOOL=FALSE because Nix's sandbox cannot
# reach Apple's closed-source `metal` compiler, so the nixpkgs build is
# CPU-only. `mlx-metal` is a separate wheel and is the piece that carries the
# Metal backend -- pinned explicitly rather than left to transitive resolution.
mlx==0.32.1
mlx-metal==0.32.1
mlx-lm==0.31.3
vllm-mlx==0.4.1
```

- [ ] **Step 2: Write the failing test**

Overwrite `tests/llm.test.sh`:

```bash
#!/usr/bin/env bash
# Verification suite for the local LLM stack (home/llm.nix).
#   bash tests/llm.test.sh
# Mirrors the ok/bad/check helper style of tests/wip.test.sh.
set -uo pipefail

VENV="$HOME/.local/share/mlx-venv"
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
have()  { command -v "$1" >/dev/null 2>&1 && ok "$1 on PATH" || bad "$1 on PATH" "not found"; }

echo "== Task 1: MLX venv on Metal =="
have uv
have llm

# Ollama and the CPU-only nixpkgs mlx were installed by the failed Revision 1
# and must be gone -- leaving them means two engines competing for 48 GB and a
# CPU-only `mlx` shadowing the real one depending on PATH order.
command -v ollama >/dev/null 2>&1 \
  && bad "ollama removed" "still on PATH at $(command -v ollama)" \
  || ok "ollama removed"

for b in python mlx_lm.generate vllm-mlx; do
  [ -x "$VENV/bin/$b" ] && ok "venv has $b" || bad "venv has $b" "missing from $VENV/bin"
done

# The assertion this whole design turns on. Revision 1 died here with
# Device(cpu, 0) because nixpkgs strips the Metal backend.
if [ -x "$VENV/bin/python" ]; then
  MLX_DEV="$("$VENV/bin/python" -c 'import mlx.core as mx; print(mx.default_device())' 2>&1 | tail -1)"
  check "mlx default device is gpu" "$MLX_DEV" "Device(gpu, 0)"

  MLX_METAL="$("$VENV/bin/python" -c 'import mlx.core as mx; print(mx.metal.is_available())' 2>&1 | tail -1)"
  check "mlx metal available" "$MLX_METAL" "True"

  # Real GPU work, not just a capability query.
  MLX_MM="$("$VENV/bin/python" -c '
import mlx.core as mx, math
a = mx.random.normal((2048, 2048))
mx.eval(a)
s = float((a @ a).sum())
print("finite" if math.isfinite(s) else "nonfinite")
' 2>&1 | tail -1)"
  check "mlx gpu matmul returns finite" "$MLX_MM" "finite"
else
  bad "mlx default device is gpu" "no venv python"
  bad "mlx metal available" "no venv python"
  bad "mlx gpu matmul returns finite" "no venv python"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 3: Run it to make sure it fails**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `uv on PATH` passes (uv is already installed). `ollama removed` FAILS — it is still on PATH from generation 28. `llm on PATH` FAILS. All three venv-binary checks FAIL. All three MLX checks FAIL with `no venv python`.

- [ ] **Step 4: Overwrite `home/llm.nix`**

```nix
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
```

Note what is **absent**: no `pkgs.ollama`, no `pkgs.python3Packages.mlx*`. Removing them is the point — the test asserts `ollama` is gone.

- [ ] **Step 5: Verify the import already exists**

Revision 1 already added `../../home/llm.nix` to the `imports` list in `users/kyle/ariane.nix`. Confirm it is there exactly once:

```bash
grep -c 'home/llm.nix' ~/nixosdotfiles/users/kyle/ariane.nix
```

Expected: `1`. If `0`, add it after `../../home/k9s.nix`. If `2`, remove the duplicate.

- [ ] **Step 6: Generate the lockfile**

`uv` is already on PATH, so the lock can be compiled before the switch.

```bash
cd ~/nixosdotfiles
uv pip compile --python-version 3.12 home/llm-requirements.in -o home/llm-requirements.txt
head -20 home/llm-requirements.txt
grep -E '^(mlx|mlx-metal|mlx-lm|vllm-mlx)==' home/llm-requirements.txt
```

Expected: the four pins appear at the versions in `home/llm-requirements.in`. If `uv pip compile` resolves a different version for any of them, stop — the pins are exact and a mismatch means PyPI moved.

- [ ] **Step 7: Stage, dry-check, and apply**

Staging first is mandatory — flakes only see git-tracked files, and three of these are new.

```bash
cd ~/nixosdotfiles
git add home/llm.nix home/llm-requirements.in home/llm-requirements.txt tests/llm.test.sh users/kyle/ariane.nix
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
home-manager switch --flake .#ariane -b backup
```

This switch **removes** ollama and the CPU-only mlx from the profile.

- [ ] **Step 8: Build the venv**

```bash
llm sync
llm doctor
```

`llm sync` downloads ~1.3 GB of wheels. `llm doctor` must report `device: Device(gpu, 0)` and `metal: True`.

- [ ] **Step 9: Run the test to verify it passes**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `9 passed, 0 failed`.

If `mlx default device is gpu` reports `Device(cpu, 0)`, **stop and report** — that is Revision 1's failure recurring and it invalidates every later task. Check that `mlx-metal` actually installed: `"$HOME/.local/share/mlx-venv/bin/python" -m pip list | grep mlx`.

- [ ] **Step 10: Commit**

```bash
cd ~/nixosdotfiles
git add home/llm.nix home/llm-requirements.in home/llm-requirements.txt tests/llm.test.sh users/kyle/ariane.nix
git status --short   # confirm ONLY these five are staged, plus the pre-existing flake.lock
git commit -m "Local LLM: Metal-enabled MLX via uv venv, replacing nixpkgs mlx+ollama" \
  -- home/llm.nix home/llm-requirements.in home/llm-requirements.txt tests/llm.test.sh users/kyle/ariane.nix
```

The explicit `--` pathspec keeps the staged `flake.lock` bump out of this commit.

---

### Task 2: Model repos resolved and downloaded

**Files:**
- Modify: `tests/llm.test.sh` (append a Task 2 section)
- Create: `docs/local-llm.md`

**Interfaces:**
- Consumes: the venv from Task 1.
- Produces: two models in `~/.cache/huggingface`, referenced by exact repo id in every later task. Both ids are **verified** (Step 1) and already substituted throughout this plan.

- [ ] **Step 1: Confirm the resolved HuggingFace repo ids**

**Both ids were resolved against the Hub API on 2026-08-24.** The planning
guess of `RadixArk/Muse-Glimmer-q4-MLX` was **wrong** and has been replaced
throughout this plan. Use these:

| Role | Repo | Safetensors | Size |
|---|---|---|---|
| Coding | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | 4 | 16 GiB |
| Agentic | `mlx-community/Muse-Glimmer-30B-4bit` | 4 | 18 GiB |

Both carry `config.json`, `tokenizer_config.json`, and `chat_template.jinja`.
The last is what tool calling depends on, so its presence was checked rather
than assumed.

`mlx-community` is the canonical MLX conversion org. Its Muse Glimmer build
has ~31.8k downloads against RadixArk's ~8.3k, and the RadixArk repos are
repacks of the vendor's llama.cpp GGUF rather than native MLX conversions.

34 GiB total against 269 GB free.

Sanity-check both still resolve before downloading — a repo can be renamed or
withdrawn:

```bash
for repo in mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit \
            mlx-community/Muse-Glimmer-30B-4bit; do
  printf '%-52s ' "$repo"
  curl -s -o /dev/null -w '%{http_code}\n' "https://huggingface.co/api/models/$repo"
done
```

Expected: `200` for both. On anything else, stop and re-resolve with
`curl -s "https://huggingface.co/api/models?search=<name>&limit=100" | jq -r '.[].id'`
rather than substituting a repo you have not checked.

- [ ] **Step 2: Write the failing test**

Append to `tests/llm.test.sh`, before the final `printf`. Substitute the ids resolved in Step 1.

```bash
echo
echo "== Task 2: models =="

CODER_REPO="mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
AGENT_REPO="mlx-community/Muse-Glimmer-30B-4bit"

# HF caches as models--<org>--<name>. Presence of a snapshot dir with a
# safetensors file is the real test; a bare directory can exist from a failed
# partial download.
hf_cached() {
  local repo="$1" dir
  dir="$HOME/.cache/huggingface/hub/models--${repo//\//--}"
  [ -d "$dir" ] && [ -n "$(find "$dir" -name '*.safetensors' -print -quit 2>/dev/null)" ]
}

hf_cached "$CODER_REPO" && ok "coder model cached ($CODER_REPO)" \
  || bad "coder model cached ($CODER_REPO)" "no safetensors under ~/.cache/huggingface"
hf_cached "$AGENT_REPO" && ok "agent model cached ($AGENT_REPO)" \
  || bad "agent model cached ($AGENT_REPO)" "no safetensors under ~/.cache/huggingface"
```

- [ ] **Step 3: Run it to verify the new section fails**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: Task 1's nine checks still pass; the two new checks FAIL.

- [ ] **Step 4: Download both models**

~36 GB total against 269 GB free. `vllm-mlx download` handles this without starting a server.

```bash
VENV=$HOME/.local/share/mlx-venv
"$VENV/bin/vllm-mlx" download mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit
"$VENV/bin/vllm-mlx" download mlx-community/Muse-Glimmer-30B-4bit
du -sh ~/.cache/huggingface
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `11 passed, 0 failed`.

- [ ] **Step 6: Measure the short-context baseline**

Raw MLX, no server, so this isolates model speed from serving overhead.

```bash
VENV=$HOME/.local/share/mlx-venv
for repo in mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit mlx-community/Muse-Glimmer-30B-4bit; do
  echo "=== $repo ==="
  "$VENV/bin/mlx_lm.generate" --model "$repo" \
    --prompt "Write a Python function that reverses a linked list." \
    --max-tokens 200 2>&1 | tail -8
done
```

`mlx_lm.generate` prints prompt and generation tok/s. Record both.

- [ ] **Step 7: Write the findings doc**

Create `docs/local-llm.md`:

```markdown
# Local LLM on ariane

Metal-enabled MLX from PyPI, served by vllm-mlx. Design rationale, the failed
nixpkgs attempt, and rejected alternatives are in
`docs/superpowers/specs/2026-08-24-local-llm-mlx-design.md`.

## Why a uv venv and not nixpkgs

nixpkgs builds `python3Packages.mlx` with `-DMLX_BUILD_METAL:BOOL=FALSE` and
`ollama` with `OLLAMA_MLX_BACKENDS=""`, because Nix's sandbox cannot reach
Apple's closed-source `metal` compiler. Both import and run — on the CPU,
silently. Apple's PyPI wheels carry the Metal backend in a separate
`mlx-metal` package.

The venv lives at `~/.local/share/mlx-venv` and is reproduced from
`home/llm-requirements.txt` by `llm sync`. `llm doctor` reports drift.

## Resolved model repos

| Role | HuggingFace repo |
|---|---|
| Coding / bulk | _fill from Task 2 Step 1_ |
| Agentic | _fill from Task 2 Step 1_ |

## Measured on ariane (M4 Pro, 48 GB)

Short context (~50-token prompt), `mlx_lm.generate`, no server:

| Model | Prompt tok/s | Generation tok/s |
|---|---|---|
| _coder_ | _fill from Step 6_ | _fill from Step 6_ |
| _agent_ | _fill from Step 6_ | _fill from Step 6_ |

Long-context figures are added by Task 7.

## GPU memory limit

`mx.device_info()` reports a **37.4 GiB** max recommended working set against
48 GB of physical memory — macOS caps GPU-addressable unified memory at ~75%
by default. With ~19 GB of weights that leaves ~18 GB for KV cache. Raise it
for a session with:

    sudo sysctl iogpu.wired_limit_mb=40960

Needs `sudo` and does not survive reboot, which is why it is documented here
rather than managed by Home Manager. `vllm-mlx --kv-cache-quantization
--kv-cache-quantization-bits 4` is the other lever and does not need root.
```

Replace every `_fill_` with a real value before committing. A committed placeholder is a plan failure.

- [ ] **Step 8: Commit**

```bash
cd ~/nixosdotfiles
git add tests/llm.test.sh docs/local-llm.md
git commit -m "Resolve MLX model repos, record short-context baseline" \
  -- tests/llm.test.sh docs/local-llm.md
```

---

### Task 3: vllm-mlx serving, with tool calling verified per model

The gate. Risk 1 lives here. Do not start Task 5 until this passes.

**Files:**
- Modify: `tests/llm.test.sh` (append a Task 3 section)
- Create: `~/.config/mlx/api-key` (never committed)
- Modify: `docs/local-llm.md` (append a "Tool calling" section)

**Interfaces:**
- Consumes: model repo ids from Task 2.
- Produces: a working `--tool-call-parser` choice per model, consumed verbatim by Task 4's serve flags. An API key file at `~/.config/mlx/api-key`, mode 0600.

- [ ] **Step 1: Generate the API key**

The repo is public and this key must never reach it.

```bash
mkdir -p ~/.config/mlx
umask 077
openssl rand -hex 32 > ~/.config/mlx/api-key
chmod 600 ~/.config/mlx/api-key
ls -l ~/.config/mlx/api-key   # must show -rw-------
```

- [ ] **Step 2: Start the coding model with its dedicated parser**

`qwen3_coder` is a purpose-built parser in vllm-mlx's list — the strongest available answer to Risk 1.

```bash
VENV=$HOME/.local/share/mlx-venv
KEY=$(cat ~/.config/mlx/api-key)
nohup "$VENV/bin/vllm-mlx" serve mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit \
  --host 127.0.0.1 --port 8000 \
  --api-key "$KEY" \
  --enable-prefix-cache --use-paged-cache \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder \
  > /tmp/vllm-mlx.log 2>&1 &

for i in $(seq 1 120); do
  sleep 2
  curl -sf -H "Authorization: Bearer $KEY" --max-time 2 \
    http://127.0.0.1:8000/v1/models >/dev/null 2>&1 && { echo "up after ~$((i*2))s"; break; }
done
tail -5 /tmp/vllm-mlx.log
```

A 30B model takes appreciably longer than the ~26 s a 1B took.

- [ ] **Step 3: Write the failing test**

Append to `tests/llm.test.sh`, before the final `printf`:

```bash
echo
echo "== Task 3: serving + tool calling =="

KEYFILE="$HOME/.config/mlx/api-key"
if [ -f "$KEYFILE" ]; then
  ok "api key file exists"
  check "api key is 0600" "$(stat -f '%Lp' "$KEYFILE")" "600"
  KEY="$(cat "$KEYFILE")"
else
  bad "api key file exists" "$KEYFILE missing"
  KEY=""
fi

AUTH=(-H "Authorization: Bearer $KEY")

# Unauthenticated requests must be refused -- the key is not decoration.
UNAUTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  http://127.0.0.1:8000/v1/models 2>/dev/null)"
case "$UNAUTH" in
  401|403) ok "unauthenticated request refused ($UNAUTH)" ;;
  *) bad "unauthenticated request refused" "got HTTP $UNAUTH, expected 401/403" ;;
esac

SERVED="$(curl -s "${AUTH[@]}" --max-time 10 http://127.0.0.1:8000/v1/models \
  | jq -r '.data[0].id // "none"' 2>/dev/null)"
[ "$SERVED" != "none" ] && ok "server lists a model ($SERVED)" \
  || bad "server lists a model" "no model from /v1/models"

# The Risk 1 assertion. A 1B probe emitted Python source instead of a tool
# call; that was a model-capability failure. This is the real test.
TOOLS='{
  "model": "MODEL_PLACEHOLDER",
  "messages": [{"role":"user","content":"What is the current weather in Asheville, NC? Use the tool."}],
  "tools": [{"type":"function","function":{
    "name":"get_weather","description":"Get the current weather for a city",
    "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
  "stream": false }'

body="${TOOLS/MODEL_PLACEHOLDER/$SERVED}"
TC="$(curl -s "${AUTH[@]}" --max-time 300 http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' -d "$body" \
  | jq -r '.choices[0].message.tool_calls[0].function.name // "none"' 2>/dev/null)"
check "tool call parsed for $SERVED" "$TC" "get_weather"

# Prefix caching must actually engage -- it is why vllm-mlx was chosen.
HITRATIO="$(curl -s "${AUTH[@]}" --max-time 10 http://127.0.0.1:8000/v1/cache/stats \
  | jq -r '.engine_cache.system_kv_cache.counters | has("hit_ratio")' 2>/dev/null)"
check "prefix cache is instrumented" "$HITRATIO" "true"
```

- [ ] **Step 4: Run it**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Unlike a normal TDD step, the tool-call check probes behaviour of a server that already exists, so it may pass on first run. Both outcomes are informative:

- **`get_weather`** → the coding model's tool calling works. Continue to Step 5.
- **`none`** → try `--tool-call-parser auto` and then `qwen`, restarting the server between attempts. Record which parser works.

If no parser produces a tool call for the coding model, **stop and report**. That is Risk 1 materialising and it blocks Task 5.

- [ ] **Step 5: Repeat for the agentic model**

Two things differ from the coding model, both established in Task 2:

- Muse Glimmer is a **VLM**, so `vllm-mlx` needs **`--mllm`**. Without it the model will not load.
- Its chat template is **harmony-format**, so start with `--tool-call-parser harmony` — not `auto`. This is evidence from the template itself, not a guess.

```bash
pkill -f 'vllm-mlx serve'; sleep 2
VENV=$HOME/.local/share/mlx-venv
KEY=$(cat ~/.config/mlx/api-key)
nohup "$VENV/bin/vllm-mlx" serve mlx-community/Muse-Glimmer-30B-4bit \
  --host 127.0.0.1 --port 8000 --api-key "$KEY" \
  --enable-prefix-cache --use-paged-cache \
  --mllm \
  --enable-auto-tool-choice --tool-call-parser harmony \
  > /tmp/vllm-mlx.log 2>&1 &
# wait for readiness as in Step 2, then re-run the tool-call curl from Step 3
```

If `harmony` fails, try in this order: `gpt-oss` (same token family), then `auto`, then `hermes`. Record the working parser, or record plainly that none worked. Loading a VLM is slower than an LLM — allow several minutes before concluding it is stuck.

- [ ] **Step 6: Record the results**

Append to `docs/local-llm.md`:

```markdown
## Tool calling

| Model | Parser that works | Verified |
|---|---|---|
| _coder_ | _e.g. qwen3_coder_ | _date_ |
| _agent_ | _e.g. auto, or "none — see below"_ | _date_ |

Server: `http://127.0.0.1:8000`, loopback only, API key at
`~/.config/mlx/api-key` (mode 0600, never committed).

Re-verify with `bash tests/llm.test.sh`.
```

Replace every italic placeholder with a real value.

- [ ] **Step 7: Commit**

```bash
cd ~/nixosdotfiles
git add tests/llm.test.sh docs/local-llm.md
git commit -m "Verify vllm-mlx serving and per-model tool-call parsers" \
  -- tests/llm.test.sh docs/local-llm.md
```

Confirm with `git status --short` that `~/.config/mlx/api-key` is nowhere in the repo — it lives in `~/.config`, outside the tree, and must stay there.

---

### Task 4: The `llm` serve commands

**Files:**
- Modify: `home/llm.nix` (extend the `llm` script)
- Modify: `tests/llm.test.sh` (append a Task 4 section)

**Interfaces:**
- Consumes: model repo ids from Task 2, working parsers from Task 3.
- Produces: `llm agent`, `llm coder`, `llm stop`, `llm status` alongside the existing `sync`, `lock`, `doctor`. Task 6 adds `long`.

- [ ] **Step 1: Write the failing test**

Append to `tests/llm.test.sh`, before the final `printf`:

```bash
echo
echo "== Task 4: llm serve commands =="

LLM_HELP="$(llm 2>&1 || true)"
for sub in sync lock doctor agent coder stop status; do
  case "$LLM_HELP" in
    *"$sub"*) ok "llm usage mentions '$sub'" ;;
    *) bad "llm usage mentions '$sub'" "usage was: ${LLM_HELP:0:200}" ;;
  esac
done

# Idempotent by contract: the normal state after a reboot is nothing running.
llm stop >/dev/null 2>&1
check "llm stop is idempotent" "$?" "0"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `sync`, `lock`, and `doctor` pass (Task 1 added them); `agent`, `coder`, `stop`, `status` FAIL; the idempotency check FAILs because `llm stop` exits 1 from the usage branch.

- [ ] **Step 3: Extend `home/llm.nix`**

Add to the `let` block, after `reqLock`. Substitute the repo ids from Task 2 and the parsers from Task 3.

```nix
  coderRepo = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit";
  coderParser = "qwen3_coder";
  agentRepo = "mlx-community/Muse-Glimmer-30B-4bit";
  # harmony, not auto: Muse Glimmer's chat template emits <|start|>/<|message|>/
  # <|eom|> and to=<recipient>, which is the harmony token family. Confirmed by
  # reading the template in Task 2. Replace with whatever Task 3 actually proved.
  agentParser = "harmony";
  # Muse Glimmer is MuseGlimmerForConditionalGeneration with a vision_config --
  # a VLM. vllm-mlx needs --mllm to load it; the coding model must not get it.
  agentMllm = true;
  port = "8000";
```

Add these branches to the `case`, before the `*)` default:

```bash
      agent) serve_model ${lib.escapeShellArg agentRepo} ${lib.escapeShellArg agentParser} ${lib.escapeShellArg (if agentMllm then "--mllm" else "")} ;;
      coder) serve_model ${lib.escapeShellArg coderRepo} ${lib.escapeShellArg coderParser} "" ;;
      status)
        if [ -f "$HOME/.config/mlx/api-key" ] && curl -sf --max-time 2 \
             -H "Authorization: Bearer $(cat "$HOME/.config/mlx/api-key")" \
             "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; then
          curl -s -H "Authorization: Bearer $(cat "$HOME/.config/mlx/api-key")" \
            "http://127.0.0.1:${port}/v1/models" | jq -r '.data[].id'
          echo "--- cache ---"
          curl -s -H "Authorization: Bearer $(cat "$HOME/.config/mlx/api-key")" \
            "http://127.0.0.1:${port}/v1/cache/stats" | jq -c '.engine_cache' 2>/dev/null || true
        else
          echo "vllm-mlx not running"
        fi
        ;;
      stop)
        # /usr/bin/pkill by absolute path, NOT via makeBinPath: nixpkgs'
        # `procps` is Linux-only (meta.platforms has no darwin), so adding it
        # would fail the build on the one machine this module targets. macOS
        # ships its own pkill and this module is darwin-gated.
        /usr/bin/pkill -f 'vllm-mlx serve' 2>/dev/null || true
        echo "stopped" >&2
        ;;
```

And add the `serve_model` helper next to `sync_venv`:

```bash
    serve_model() {
      local repo="$1" parser="$2" extra="''${3-}"
      local keyfile="$HOME/.config/mlx/api-key"
      if [ ! -f "$keyfile" ]; then
        echo "no API key at $keyfile -- create one with:" >&2
        echo "  mkdir -p ~/.config/mlx && (umask 077; openssl rand -hex 32 > $keyfile)" >&2
        exit 1
      fi
      if [ ! -x "$VENV/bin/vllm-mlx" ]; then
        echo "venv missing -- run: llm sync" >&2
        exit 1
      fi
      # Only one model fits at a time: ~19 GB of weights against a 37.4 GiB
      # GPU working set. Evict whatever is running before loading another.
      /usr/bin/pkill -f 'vllm-mlx serve' 2>/dev/null || true
      sleep 1
      echo "serving $repo (parser: $parser) on 127.0.0.1:${port}" >&2
      exec "$VENV/bin/vllm-mlx" serve "$repo" \
        --host 127.0.0.1 --port ${port} \
        --api-key "$(cat "$keyfile")" \
        --enable-prefix-cache --use-paged-cache \
        --kv-cache-quantization --kv-cache-quantization-bits 4 \
        --enable-auto-tool-choice --tool-call-parser "$parser" \
        ''${extra:+$extra} \
        --offline
    }
```

`--offline` is safe here because Task 2 already downloaded both models; it is the PHI guarantee that the server makes no network calls during inference.

Update the usage heredoc to list all seven subcommands.

- [ ] **Step 4: Stage, dry-check, apply**

```bash
cd ~/nixosdotfiles
git add home/llm.nix
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
home-manager switch --flake .#ariane -b backup
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `24 passed, 0 failed`.

- [ ] **Step 6: Verify the memory actually comes back**

On-demand is the whole justification for not running a launchd agent. Confirm `stop` frees the memory rather than assuming it.

```bash
llm coder &
sleep 90
llm status
ps -o rss= -p "$(pgrep -f 'vllm-mlx serve' | head -1)" | awk '{printf "RSS: %.1f GiB\n", $1/1048576}'
llm stop
sleep 2
pgrep -f 'vllm-mlx serve' >/dev/null && echo "STILL RUNNING" || echo "no vllm-mlx process"
```

- [ ] **Step 7: Commit**

```bash
cd ~/nixosdotfiles
git add home/llm.nix
git commit -m "Add llm serve/stop/status commands for on-demand vllm-mlx" -- home/llm.nix
```

---

### Task 5: OpenCode wired to the local provider, PHI hardened

**Files:**
- Modify: `home/llm.nix` (add the `xdg.configFile` block)
- Modify: `tests/llm.test.sh` (append a Task 5 section)

**Interfaces:**
- Consumes: port 8000, the API key path, model repo ids.
- Produces: `~/.config/opencode/opencode.json`, Home Manager–managed and read-only.

- [ ] **Step 1: Write the failing test**

Append to `tests/llm.test.sh`, before the final `printf`:

```bash
echo
echo "== Task 5: opencode + PHI hardening =="

CFG="$HOME/.config/opencode/opencode.json"
[ -f "$CFG" ] && ok "opencode config exists" || bad "opencode config exists" "$CFG missing"

if [ -f "$CFG" ]; then
  check "share is disabled" "$(jq -r '.share' "$CFG")" "disabled"
  check "autoupdate is off"  "$(jq -r '.autoupdate' "$CFG")" "false"
  check "baseURL is loopback" \
    "$(jq -r '.provider.mlx.options.baseURL' "$CFG")" \
    "http://127.0.0.1:8000/v1"

  # Zero cloud providers. The whole PHI case rests on this one assertion.
  check "only the local provider is configured" \
    "$(jq -r '.provider | keys | join(",")' "$CFG")" "mlx"

  # Managed by Home Manager means a store symlink, which means a cloud
  # provider cannot be added by an in-place edit.
  [ -L "$CFG" ] && ok "config is a nix store symlink" \
                || bad "config is a nix store symlink" "it is a plain file"

  # The API key must be read from disk at runtime, never baked into a
  # world-readable store path.
  if grep -qE '[0-9a-f]{64}' "$CFG" 2>/dev/null; then
    bad "no API key literal in config" "a 64-hex string is present"
  else
    ok "no API key literal in config"
  fi
fi

# Nothing may listen off-loopback.
OFFLOOP="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
  | grep -Ei 'vllm|mlx|llama' | grep -v '127\.0\.0\.1' | wc -l | tr -d ' ')"
check "no off-loopback llm listeners" "$OFFLOOP" "0"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `opencode config exists` FAILs and the jq checks are skipped. The `lsof` check may already pass — it is a regression guard.

- [ ] **Step 3: Add the config to `home/llm.nix`**

Append inside the top-level attribute set, after `home.packages`:

```nix
  # OpenCode's local profile. Written through xdg.configFile so it lands as a
  # read-only store symlink -- a cloud provider cannot be added by an
  # accidental in-place edit, which tests/llm.test.sh asserts.
  #
  # `provider` deliberately contains exactly one entry. Every PHI guarantee in
  # the spec reduces to that fact plus the loopback baseURL.
  #
  # The API key is NOT written here. Nix store paths are world-readable, and
  # this repo is public; the key stays in ~/.config/mlx/api-key at 0600 and is
  # supplied through the OPENCODE_MLX_API_KEY environment variable, which
  # home.sessionVariables populates below by reading that file at shell init.
  xdg.configFile."opencode/opencode.json" = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      share = "disabled";
      autoupdate = false;
      provider = {
        mlx = {
          npm = "@ai-sdk/openai-compatible";
          name = "MLX (local, vllm-mlx)";
          options = {
            baseURL = "http://127.0.0.1:8000/v1";
            apiKey = "{env:OPENCODE_MLX_API_KEY}";
          };
          models = {
            "${coderRepo}" = { name = "Qwen3-Coder 30B A3B — coding"; tools = true; };
            "${agentRepo}" = { name = "Muse Glimmer 30B — agentic"; tools = true; };
          };
        };
      };
    };
  };

  programs.fish.interactiveShellInit = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (lib.mkAfter ''
    # OpenCode reads {env:OPENCODE_MLX_API_KEY} from its config. Sourced from
    # the 0600 file rather than written into the world-readable nix store.
    if test -r "$HOME/.config/mlx/api-key"
        set -gx OPENCODE_MLX_API_KEY (cat "$HOME/.config/mlx/api-key")
    end
  '');
```

- [ ] **Step 4: Stage, dry-check, apply**

```bash
cd ~/nixosdotfiles
git add home/llm.nix
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
home-manager switch --flake .#ariane -b backup
```

If activation fails with a clobber error on `~/.config/opencode/opencode.json`, an unmanaged file is in the way. Inspect it before moving it — do not delete blind:

```bash
cat ~/.config/opencode/opencode.json
mv ~/.config/opencode/opencode.json ~/.config/opencode/opencode.json.pre-nix
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `32 passed, 0 failed`.

- [ ] **Step 6: End-to-end through OpenCode, with a network audit**

```bash
llm coder &
sleep 90
cd /tmp && rm -rf llm-scratch && mkdir llm-scratch && cd llm-scratch
git init -q && echo 'def add(a, b): return a - b' > calc.py && git add -A
git -c user.email=kmello@broadriverrehab.com -c user.name=kyle commit -qm init

# In a second terminal, watch for non-loopback connections:
#   lsof -nP -iTCP -a -c opencode -r2 | grep -v 127.0.0.1
opencode run --model mlx/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit "Fix the bug in calc.py"
```

Record in `docs/local-llm.md` whether anything non-loopback appeared. Anything other than loopback is a finding to report, not to wave through.

- [ ] **Step 7: Commit**

```bash
cd ~/nixosdotfiles
git add home/llm.nix
git commit -m "Wire OpenCode to the local MLX provider, loopback-only, key off-store" -- home/llm.nix
```

---

### Task 6: llama.cpp escape hatch for prompts past 60K

Retained but **demoted** — vllm-mlx's paged + prefix + SSD caching addresses much of the long-context weakness that originally justified this. Build it, measure it in Task 7, and let the numbers decide whether it earns its place.

**Files:**
- Modify: `flake.nix` (inputs block, outputs destructure, overlays list)
- Modify: `home/llm.nix` (add `llama-cpp`, add the `long` subcommand)
- Modify: `tests/llm.test.sh` (append a Task 6 section)

**Interfaces:**
- Consumes: the `llm` dispatch from Task 4.
- Produces: `llama-server` on PATH at build ≥ b10353, and `llm long <gguf-path>`.

- [ ] **Step 1: Write the failing test**

Append to `tests/llm.test.sh`, before the final `printf`:

```bash
echo
echo "== Task 6: llama.cpp escape hatch =="
have llama-server

# Muse Glimmer support landed in b10353. The pinned nixpkgs ships b10273,
# which would load the weights and produce garbage rather than fail loudly.
BUILD="$(llama-server --version 2>&1 | grep -oE 'build: [0-9]+' | grep -oE '[0-9]+' | head -1)"
if [ -n "$BUILD" ] && [ "$BUILD" -ge 10353 ]; then
  ok "llama-server build $BUILD >= 10353"
else
  bad "llama-server build >= 10353" "got [${BUILD:-none}]"
fi
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `llama-server on PATH: not found` and `llama-server build >= 10353: got [none]`.

- [ ] **Step 3: Add the pinned input to `flake.nix`**

In the `inputs` block, after the `bitbucket-cli` entry:

```nix
    # llama.cpp only, pinned separately from the main nixpkgs. The escape hatch
    # for prompts past ~60K tokens. Muse Glimmer support landed in llama.cpp
    # b10353; the pinned nixos-unstable ships b10273, which is too old. A full
    # `nix flake update` would fix it and rebuild the world -- this pins one
    # package instead.
    nixpkgs-llama.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
```

In the outputs destructure, add `nixpkgs-llama`:

```nix
  outputs = inputs@{ self, nixpkgs, flake-utils, home-manager, nixos-wsl, claude-code, bitbucket-cli, nixpkgs-llama, ... }:
```

In the `overlays` list, after the `bitbucket-cli` overlay:

```nix
        (final: prev: {
          llama-cpp = nixpkgs-llama.legacyPackages.${prev.stdenv.hostPlatform.system}.llama-cpp;
        })
```

- [ ] **Step 4: Confirm the pinned input is new enough before switching**

`nixpkgs-unstable` moves. Check the actual version rather than trusting the b10408 reading taken on 2026-08-24:

```bash
cd ~/nixosdotfiles
nix flake update nixpkgs-llama
nix eval --raw "$(nix flake metadata --json | jq -r '.locks.nodes["nixpkgs-llama"].locked | "github:\(.owner)/\(.repo)/\(.rev)"')#llama-cpp.version"
```

Expected: a number ≥ 10353. If lower, the branch regressed — pin an explicit known-good rev instead of the branch name.

- [ ] **Step 5: Add `llama-cpp` and the `long` subcommand**

Add `pkgs.llama-cpp` to `home.packages`, and add it to the script's `makeBinPath` list so `llama-server` resolves inside `llm`:

```nix
    export PATH="${lib.makeBinPath (with pkgs; [ uv curl coreutils jq gnugrep llama-cpp ])}:$PATH"
```

Add a `long` branch to the `case`, before `*)`:

```bash
      long)
        gguf="''${2-}"
        if [ -z "$gguf" ] || [ ! -f "$gguf" ]; then
          echo "usage: llm long <path-to.gguf>" >&2
          echo "the escape hatch for prompts past ~60K tokens, where MLX" >&2
          echo "runs at roughly half llama.cpp+flash-attention on decode." >&2
          echo "no GGUF is downloaded by this setup -- fetch one yourself." >&2
          exit 1
        fi
        /usr/bin/pkill -f 'vllm-mlx serve' 2>/dev/null || true
        exec llama-server \
          --model "$gguf" \
          --host 127.0.0.1 --port 8080 \
          --ctx-size 131072 \
          --flash-attn \
          --n-gpu-layers 99 \
          --jinja
        ;;
```

Add `long` to the usage heredoc.

- [ ] **Step 6: Stage, dry-check, apply**

```bash
cd ~/nixosdotfiles
git add flake.nix flake.lock home/llm.nix
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
home-manager switch --flake .#ariane -b backup
```

`llama-cpp` from a different nixpkgs may not be in the binary cache and can take several minutes to compile against Metal. That is expected, not a failure.

- [ ] **Step 7: Run the test to verify it passes**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `34 passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
cd ~/nixosdotfiles
git diff --cached --stat flake.lock   # inspect BEFORE committing
git add flake.nix flake.lock home/llm.nix tests/llm.test.sh
git commit -m "Pin llama-cpp >= b10353 as the long-context escape hatch" \
  -- flake.nix flake.lock home/llm.nix tests/llm.test.sh
```

`flake.lock` carries a **pre-existing 15-line input bump** that predates this plan, plus the new `nixpkgs-llama` node. Both are intended. Confirm the diff contains nothing else.

---

### Task 7: Long-context measurement, routing rule, and the end-to-end agent run

Writes the "which model when" rule from ariane's numbers instead of vendor claims.

**Files:**
- Modify: `docs/local-llm.md`
- Modify: `docs/superpowers/specs/2026-08-24-local-llm-mlx-design.md` (status line)

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: no code. A documented routing rule and a status change.

- [ ] **Step 1: Raise the GPU memory limit**

```bash
sudo sysctl iogpu.wired_limit_mb=40960
sysctl iogpu.wired_limit_mb
$HOME/.local/share/mlx-venv/bin/python -c \
  'import mlx.core as mx; print(round(mx.device_info()["max_recommended_working_set_size"]/2**30,1), "GiB")'
```

Expected: `iogpu.wired_limit_mb: 40960`, and the reported working set rising from 37.4 GiB. Does not survive reboot, by design.

- [ ] **Step 2: Build a ~40K-token prompt**

```bash
cd /tmp
# ~40K tokens at roughly 4 chars/token = ~160KB of real source text.
find /nix/store -maxdepth 4 -name '*.py' -size +4k 2>/dev/null | head -40 \
  | xargs cat 2>/dev/null | head -c 160000 > big-prompt.txt
wc -c big-prompt.txt
```

- [ ] **Step 3: Measure time-to-first-token at 40K**

The spec's central open risk is a third-party report of 3.5 minutes to first token at 40K on plain `mlx_lm.server`. vllm-mlx's paged and prefix caching is supposed to fix exactly this. Measure it.

```bash
KEY=$(cat ~/.config/mlx/api-key)
llm coder & sleep 120

PROMPT=$(jq -Rs . < /tmp/big-prompt.txt)
for run in 1 2; do
  echo "=== run $run (run 2 should hit the prefix cache) ==="
  curl -s -o /dev/null -w 'total: %{time_total}s  ttfb: %{time_starttransfer}s\n' \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    --max-time 900 http://127.0.0.1:8000/v1/chat/completions \
    -d "{\"model\":\"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit\",
         \"messages\":[{\"role\":\"user\",\"content\":$PROMPT}],
         \"max_tokens\":64,\"stream\":false}"
done
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8000/v1/cache/stats \
  | jq '.engine_cache.system_kv_cache.counters'
```

The run-1 vs run-2 gap and the `hit_ratio` are the measurement that justifies or refutes the whole vllm-mlx choice. Repeat for the agentic model.

- [ ] **Step 4: Record the routing rule**

Append to `docs/local-llm.md`:

```markdown
## Measured: long context (~40K tokens)

| Model | Run 1 TTFB | Run 2 TTFB (cached) | Cache hit ratio |
|---|---|---|---|
| _coder_ | _fill_ | _fill_ | _fill_ |
| _agent_ | _fill_ | _fill_ | _fill_ |

## Which model when

Written from the numbers above, not from vendor claims.

- `llm coder` — bulk work, completions, anything where throughput matters.
- `llm agent` — multi-step tool use, where recovering from a failed call
  matters more than tok/s.
- `llm long <gguf>` — prompts past the crossover point measured above. If
  vllm-mlx's prefix cache holds up at 40K, this may never be needed; say so
  here explicitly rather than leaving it implied.

## Pointing Claude Code at this server

vllm-mlx serves an Anthropic-compatible `/v1/messages` endpoint (verified
returning HTTP 200), so Claude Code itself can use the local models:

    ANTHROPIC_BASE_URL=http://127.0.0.1:8000 \
    ANTHROPIC_API_KEY=$(cat ~/.config/mlx/api-key) \
    claude

Untested as of writing — try it before relying on it.
```

Replace every `_fill_` with a real number.

- [ ] **Step 5: Run the full end-to-end agent task**

Multi-file, multi-tool, not a toy:

```bash
cd /tmp && rm -rf llm-e2e && mkdir llm-e2e && cd llm-e2e && git init -q
cat > inventory.py <<'PY'
def total_value(items):
    total = 0
    for item in items:
        total += item["price"] * item["qty"]
    return total
PY
git add -A && git -c user.email=kmello@broadriverrehab.com -c user.name=kyle commit -qm init

llm agent & sleep 120
opencode run --model mlx/mlx-community/Muse-Glimmer-30B-4bit \
  "Add a tests/ directory with pytest tests for total_value, including an empty-list case and a case with a missing 'qty' key. Then fix total_value to handle the missing key without raising."
```

Record: did it complete, how many tool calls, how long, and does the result actually run (`python -m pytest tests/`)?

- [ ] **Step 6: Run the full suite one final time**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `34 passed, 0 failed`.

- [ ] **Step 7: Update the spec status**

In `docs/superpowers/specs/2026-08-24-local-llm-mlx-design.md`, change:

```
**Status:** Design approved, pending implementation plan
```

to:

```
**Status:** Implemented 2026-08-__ per the Amendment (PyPI MLX + vllm-mlx).
Measured results in `docs/local-llm.md`.
```

Fill the real date.

- [ ] **Step 8: Commit**

```bash
cd ~/nixosdotfiles
git add docs/local-llm.md docs/superpowers/specs/2026-08-24-local-llm-mlx-design.md
git commit -m "Record measured MLX performance and the model routing rule" \
  -- docs/local-llm.md docs/superpowers/specs/2026-08-24-local-llm-mlx-design.md
```

---

## Self-review notes

**Spec coverage.** Amendment's replacement engine → Tasks 1, 3, 4. PyPI/uv decision → Task 1. Models → Task 2. Tool calling (Risk 1) → Task 3. PHI hardening → Tasks 3 (API key), 4 (`--offline`), 5 (config + lsof audit). Memory headroom → Task 2 doc, Task 4 (`--kv-cache-quantization`), Task 7 Step 1. llama.cpp escape hatch → Task 6. Measurement → Tasks 2, 7.

**Changes from Revision 1, all forced by the nixpkgs finding:**

- Ollama dropped entirely; Task 1 now asserts its *removal*.
- `mlx_lm.server` never adopted; vllm-mlx is primary, which pulls the spec's phase-2 option forward.
- Port 11434 → 8000. Model tags → HuggingFace repo ids.
- API-key auth added throughout — vllm-mlx warns loudly without it, and the test asserts unauthenticated requests are refused.
- `--offline` added as an explicit PHI control.
- `--kv-cache-quantization-bits 4` added; it is a root-free lever on the 48 GB ceiling that Revision 1 had no answer for.
- Test totals: 9 / 11 / 17 / 24 / 32 / 34.

**Deliberate scope narrowing:** `llm long` still requires an explicit GGUF path because no task downloads a GGUF — HuggingFace MLX repos are safetensors, not GGUF. Acquiring one is left out rather than half-specified.

**Not verified during planning, flagged in-task rather than guessed:** which tool-call parser each model needs (Task 3 — there is no `muse` parser), whether `nixpkgs-unstable` still carries llama.cpp ≥ b10353 (Task 6 Step 4), and whether Claude Code actually works against `/v1/messages` (Task 7 Step 4 documents it as untested).
