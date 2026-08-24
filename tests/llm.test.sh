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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
