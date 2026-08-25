#!/usr/bin/env bash
# Verification suite for the local LLM stack (home/llm.nix).
#   bash tests/llm.test.sh
# Mirrors the ok/bad/check helper style of tests/wip.test.sh.
#
# Checks marked [live] need a running server and are skipped when none is up;
# start one with `llm coder` first to exercise them.
set -uo pipefail

VENV="$HOME/.local/share/mlx-venv"
KEYFILE="$HOME/.config/mlx/api-key"
PORT=8000
CODER="mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
AGENT="mlx-community/Qwen3.6-35B-A3B-4bit"
HARD="mlx-community/Qwen3.8-27B-4bit"

PASS=0; FAIL=0; SKIP=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
skip()  { SKIP=$((SKIP+1)); printf '  skip %s (%s)\n' "$1" "${2:-}"; }
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
  check "mlx default device is gpu" \
    "$("$VENV/bin/python" -c 'import mlx.core as mx; print(mx.default_device())' 2>&1 | tail -1)" \
    "Device(gpu, 0)"
  check "mlx metal available" \
    "$("$VENV/bin/python" -c 'import mlx.core as mx; print(mx.metal.is_available())' 2>&1 | tail -1)" \
    "True"
  check "mlx gpu matmul returns finite" \
    "$("$VENV/bin/python" -c '
import mlx.core as mx, math
a = mx.random.normal((2048, 2048)); mx.eval(a)
print("finite" if math.isfinite(float((a @ a).sum())) else "nonfinite")' 2>&1 | tail -1)" \
    "finite"
else
  bad "mlx default device is gpu" "no venv python"
  bad "mlx metal available" "no venv python"
  bad "mlx gpu matmul returns finite" "no venv python"
fi

echo
echo "== Task 2: models =="
# Presence of a snapshot dir with a safetensors file is the real test; a bare
# directory can survive a failed partial download.
hf_cached() {
  local repo="$1" dir
  dir="$HOME/.cache/huggingface/hub/models--${repo//\//--}"
  [ -d "$dir" ] && [ -n "$(find "$dir" -name '*.safetensors' -print -quit 2>/dev/null)" ]
}
for pair in "coder:$CODER" "agent:$AGENT" "hard:$HARD"; do
  role="${pair%%:*}"; repo="${pair#*:}"
  hf_cached "$repo" && ok "$role model cached ($repo)" \
    || bad "$role model cached ($repo)" "no safetensors under ~/.cache/huggingface"
done

echo
echo "== Task 3: API key + PHI hardening =="
if [ -f "$KEYFILE" ]; then
  ok "api key file exists"
  check "api key is 0600" "$(stat -f '%Lp' "$KEYFILE")" "600"
else
  bad "api key file exists" "$KEYFILE missing"
fi
# The key must never be committed -- this repo is public. Search for the key's
# CONTENT, not a guessed path: the previous version probed
# <repo>/.config/mlx/api-key, which has never existed, so it could not detect
# the key being committed under any real path.
if [ -f "$KEYFILE" ]; then
  if git -C "$(dirname "$0")/.." grep -qF -- "$(cat "$KEYFILE")" 2>/dev/null; then
    bad "api key not committed" "key content found in tracked files"
  else
    ok "api key not committed"
  fi
else
  skip "api key not committed" "no key file to search for"
fi
# Nothing may listen off-loopback.
#
# Target the PORT, not the process name. The previous version of this check
# grepped `lsof` output for 'vllm|mlx|llama' -- but lsof truncates COMMAND to 9
# characters and the server renders as "python3.1", so NO field on the line
# ever matched. The pre-filter emptied the pipeline, `grep -cv` printed 0, and
# the check passed with 25 live listeners present, with no server running, and
# would have passed with a server bound to 0.0.0.0. It was structurally
# incapable of failing, while being the sole evidence for the PHI claim
# "binds 127.0.0.1 only".
for p in 8000 8080; do
  LISTEN_ADDRS="$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -Fn 2>/dev/null | grep '^n' | sed 's/^n//')"
  if [ -z "$LISTEN_ADDRS" ]; then
    skip "no off-loopback listener on :$p" "nothing listening"
  else
    check "no off-loopback listener on :$p" \
      "$(printf '%s\n' "$LISTEN_ADDRS" | grep -cvE '^(127\.0\.0\.1|\[::1\]):' | tr -d ' ')" "0"
  fi
done

echo
echo "== Task 4: llm command =="
LLM_HELP="$(llm 2>&1 || true)"
for sub in sync lock doctor coder agent hard long status stop; do
  case "$LLM_HELP" in
    *"$sub"*) ok "llm usage mentions '$sub'" ;;
    *) bad "llm usage mentions '$sub'" "usage was: ${LLM_HELP:0:160}" ;;
  esac
done
# `llm stop` is destructive, so only exercise it when nothing is serving --
# otherwise this check tears down the server that the [live] section below
# needs, and the live checks silently skip. (It did exactly that once.)
if pgrep -f 'vllm-mlx serve' >/dev/null 2>&1; then
  skip "llm stop is idempotent" "server is live; would kill it"
else
  llm stop >/dev/null 2>&1
  check "llm stop is idempotent" "$?" "0"
fi

echo
echo "== Task 5: opencode config =="
CFG="$HOME/.config/opencode/opencode.json"
if [ -f "$CFG" ]; then
  ok "opencode config exists"
  check "share is disabled"   "$(jq -r '.share' "$CFG")" "disabled"
  check "autoupdate is off"   "$(jq -r '.autoupdate' "$CFG")" "false"
  check "baseURL is loopback" "$(jq -r '.provider.mlx.options.baseURL' "$CFG")" "http://127.0.0.1:8000/v1"
  # Zero cloud providers. The whole PHI case rests on this one assertion.
  check "only the local provider is configured" "$(jq -r '.provider | keys | join(",")' "$CFG")" "mlx"
  check "all three models declared" "$(jq -r '.provider.mlx.models | keys | length' "$CFG")" "3"
  [ -L "$CFG" ] && ok "config is a nix store symlink" \
                || bad "config is a nix store symlink" "it is a plain file"
  # The key itself must never reach the world-readable nix store.
  if grep -qE '\b[0-9a-f]{64}\b' "$CFG" 2>/dev/null; then
    bad "no API key literal in config" "a 64-hex string is present"
  else
    ok "no API key literal in config"
  fi
else
  bad "opencode config exists" "$CFG missing"
fi

echo
echo "== Task 6: llama.cpp escape hatch =="
have llama-server
# Metal must survive in the nixpkgs build, or the hatch is worthless. Unlike
# mlx/ollama, llama.cpp JIT-compiles its Metal shaders at runtime.
if command -v llama-server >/dev/null 2>&1; then
  BUILD="$(llama-server --version 2>&1 |  grep -oE 'build [0-9]+' | grep -oE '[0-9]+' | head -1)"
  if [ -n "$BUILD" ] && [ "$BUILD" -ge 10353 ]; then
    ok "llama-server build $BUILD >= 10353"
  else
    bad "llama-server build >= 10353" "got [${BUILD:-none}]"
  fi
fi

echo
echo "== live server checks =="
if [ -f "$KEYFILE" ] && curl -sf --max-time 2 -H "Authorization: Bearer $(cat "$KEYFILE")" \
     "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
  KEY="$(cat "$KEYFILE")"
  check "[live] unauthenticated request refused" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/v1/models")" "401"
  SERVED="$(curl -s -H "Authorization: Bearer $KEY" --max-time 10 \
    "http://127.0.0.1:$PORT/v1/models" | jq -r '.data[0].id // "none"')"
  [ "$SERVED" != "none" ] && ok "[live] server lists a model ($SERVED)" \
                          || bad "[live] server lists a model" "none returned"
  TC="$(curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' --max-time 300 \
    "http://127.0.0.1:$PORT/v1/chat/completions" -d "{
      \"model\":\"$SERVED\",
      \"messages\":[{\"role\":\"user\",\"content\":\"Read the file /etc/hosts for me.\"}],
      \"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"read_file\",
        \"description\":\"Read a file from disk\",
        \"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}}],
      \"stream\":false}" | jq -r '.choices[0].message.tool_calls[0].function.name // "none"')"
  check "[live] tool call parsed for $SERVED" "$TC" "read_file"

  # Run LAST, and only here: `llm stop` terminating a real server was
  # previously covered in neither mode -- skipped while one was live, and only
  # the no-op path exercised while none was. `pkill -f 'vllm-mlx serve'` is the
  # most breakage-prone line in the module (an upstream rename or a
  # setproctitle call would silently break eviction) and had zero coverage.
  llm stop >/dev/null 2>&1
  sleep 2
  /usr/bin/pgrep -f 'vllm-mlx serve' >/dev/null 2>&1 \
    && bad "[live] llm stop kills a running server" "still running after stop" \
    || ok "[live] llm stop kills a running server"
else
  skip "[live] server checks" "no vllm-mlx running; start one with 'llm coder'"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
