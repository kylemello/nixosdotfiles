# Local LLM on ariane (MLX + OpenCode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Qwen3-Coder-30B-A3B and Muse Glimmer 30B entirely on ariane via Ollama's MLX engine, driven by OpenCode, with llama.cpp retained for prompts past 60K tokens.

**Architecture:** A new Home Manager module `home/llm.nix` installs Ollama and an MLX Python environment, pins loopback-only environment variables, and exposes an `llm` shell command for on-demand model serving. OpenCode gets a declarative local-provider config with every cloud provider absent. A separately-pinned nixpkgs input supplies a `llama-cpp` new enough to load Muse Glimmer.

**Tech Stack:** Nix flakes + standalone Home Manager, Ollama 0.32.6 (MLX backend), `python3Packages.mlx` 0.32.0 / `mlx-lm` 0.31.3, llama.cpp ≥ b10353, OpenCode 1.18.x, fish.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from `docs/superpowers/specs/2026-08-24-local-llm-mlx-design.md`.

- **Bind loopback only (`127.0.0.1`). Never `0.0.0.0`.** Applies to every server started by any task.
- **`OLLAMA_HOST=127.0.0.1` set explicitly in the module, not relied on as default.**
- **The OpenCode local profile carries zero cloud providers.**
- **`"share": "disabled"` in the OpenCode config.**
- **`llama-cpp` must be ≥ b10353.** Pinned nixpkgs currently supplies b10273; unstable HEAD supplies b10408.
- **`iogpu.wired_limit_mb=40960`** — needs `sudo`, does not survive reboot, cannot be Home Manager–managed. Documented, never scripted into activation.
- **On-demand only. No launchd agent.** A ~19 GB permanent reservation on 48 GB is out of scope.
- **Model weights live outside the Nix store** (Ollama's `~/.ollama`, MLX's `~/.cache/huggingface`).
- **The repo working tree is dirty with pre-existing unrelated changes** (`claude/local/ariane.json`, `claude/settings.json`, `nvim/lazy-lock.json`, `flake.lock`). Every commit in this plan stages explicit paths. Never `git add -A`, never `git commit -a`.
- **Every speed number in the spec is third-party.** No task may cite a spec figure as an observed result.
- **New files must be `git add`ed before any `nix` eval or switch reads them.** Per `CLAUDE.md`: flakes only see git-tracked files. This bites `home/llm.nix` in Task 1.
- **The coding model's tag is resolved once, in Task 2 Step 1.** The plan writes `qwen3-coder:30b` as a placeholder in Tasks 2, 4, and 5. If Step 1 resolves a different tag, update all three — `tests/llm.test.sh`, the `coderModel` binding in `home/llm.nix`, and the OpenCode `models` key — or the test and the config will disagree silently.
- **This repo is public** (`github.com/kylemello/nixosdotfiles`). Nothing in this plan is credential-shaped, but `docs/local-llm.md` and the benchmark output are world-readable once pushed. Don't paste work data or internal URLs into the measurement notes.

**Switch command, used throughout:**

```bash
cd ~/nixosdotfiles && home-manager switch --flake .#ariane -b backup
```

---

### Task 1: MLX and Ollama installed, MLX proven to be on the GPU

The foundation. Nothing later is meaningful if MLX silently falls back to CPU.

**Files:**
- Create: `home/llm.nix`
- Create: `tests/llm.test.sh`
- Modify: `users/kyle/ariane.nix` (imports list, after `../../home/k9s.nix`)

**Interfaces:**
- Consumes: nothing.
- Produces: `pkgs`-provided binaries on PATH — `ollama`, `mlx_lm.generate`, `mlx_lm.server`, `mlx_lm.convert`, and a `python` with `mlx` importable. Environment variables `OLLAMA_HOST`, `OLLAMA_CONTEXT_LENGTH`, `OLLAMA_FLASH_ATTENTION`. Test harness functions `ok`, `bad`, `check`, `have` in `tests/llm.test.sh`.

- [ ] **Step 1: Write the failing test**

Create `tests/llm.test.sh`. It mirrors the helper style of `tests/wip.test.sh` (same `ok`/`bad`/`check` shape) so the two read alike.

```bash
#!/usr/bin/env bash
# Verification suite for the local LLM stack (home/llm.nix).
#   bash tests/llm.test.sh
# Unlike tests/wip.test.sh this needs no `nix shell` wrapper -- every binary it
# probes is expected to be on PATH via home-manager, and that expectation is
# itself part of what is under test.
set -uo pipefail

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
have()  { command -v "$1" >/dev/null 2>&1 && ok "$1 on PATH" || bad "$1 on PATH" "not found"; }

echo "== Task 1: toolchain =="
have ollama
have mlx_lm.generate
have mlx_lm.server

# Resolve the interpreter from the MLX env itself, NOT from a bare `python`
# on PATH. There is no bare `python` on this machine, `python3` is Homebrew's
# /opt/homebrew/bin/python3 (no mlx), and whether the nix profile wins depends
# on PATH ordering. Deriving it from a console script the env owns is exact.
MLX_PY="$(dirname "$(command -v mlx_lm.generate 2>/dev/null || echo /nonexistent/x)")/python"
if [ -x "$MLX_PY" ]; then
  ok "mlx env python resolved ($MLX_PY)"
else
  bad "mlx env python resolved" "no python next to mlx_lm.generate"
fi

# MLX must resolve to the GPU. A CPU fallback here would make every
# benchmark in later tasks meaningless while still "working".
MLX_DEV="$("$MLX_PY" -c 'import mlx.core as mx; print(mx.default_device())' 2>&1 | tail -1)"
check "mlx default device is gpu" "$MLX_DEV" "Device(gpu, 0)"

# A real matmul on the GPU, not just a device query. 2048x2048 normal matrix
# squared and summed -- we assert only that it produces a finite float, since
# the value is random.
MLX_MM="$("$MLX_PY" -c '
import mlx.core as mx, math
a = mx.random.normal((2048, 2048))
s = float((a @ a).sum())
print("finite" if math.isfinite(s) else "nonfinite")
' 2>&1 | tail -1)"
check "mlx gpu matmul returns finite" "$MLX_MM" "finite"

check "OLLAMA_HOST is loopback" "${OLLAMA_HOST:-unset}" "127.0.0.1:11434"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: FAIL on every check — `ollama on PATH: not found`, `mlx_lm.generate on PATH: not found`, `mlx env python resolved: no python next to mlx_lm.generate`, the two MLX checks failing because `$MLX_PY` does not exist, and `OLLAMA_HOST` `unset`.

- [ ] **Step 3: Write `home/llm.nix`**

```nix
{ config, lib, pkgs, ... }:

# Local LLM stack for ariane -- Ollama on its MLX backend, plus a Python
# environment with MLX itself for benchmarking and quantizing.
#
# Ollama rather than raw `mlx_lm.server` for one reason: snapshot caching.
# Agent loops resend the whole transcript on every tool call, so the model
# reprocesses the same context dozens of times per task. Ollama's MLX engine
# stores reusable state at checkpoints and processes only the delta;
# mlx_lm.server has no equivalent, and without it MLX's long-context weakness
# (~50% of llama.cpp+flash-attention past ~60K prompt tokens) lands squarely
# on the agentic use case. mlx-lm is still installed below, but as a
# measurement side channel, not in the agent path.
#
# Darwin-only by construction: MLX is Metal. The `lib.optionals` guard keeps
# this module inert if it is ever imported from a Linux profile.
let
  # Both the console scripts (mlx_lm.generate, mlx_lm.server, mlx_lm.convert)
  # and an importable `mlx` for the GPU checks in tests/llm.test.sh. A bare
  # `python3Packages.mlx-lm` in home.packages would give the scripts but leave
  # `python -c 'import mlx.core'` broken, which is exactly what the test asserts.
  mlxPython = pkgs.python3.withPackages (ps: with ps; [
    mlx
    mlx-lm
  ]);
in
{
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.ollama
    mlxPython
  ];

  home.sessionVariables = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    # Loopback, explicitly. Ollama's own default is already localhost, but this
    # is the single control that keeps PHI-bearing prompts off the network, so
    # it is pinned rather than inherited. Any change here needs the lsof audit
    # in tests/llm.test.sh re-run.
    OLLAMA_HOST = "127.0.0.1:11434";

    # Ollama's historical default context is 4096 tokens and it truncates
    # SILENTLY past that -- an agent transcript would lose its head mid-task
    # with no error surfaced anywhere. 32768 is chosen to sit under the ~60K
    # point where MLX's long-context penalty bites; `llm long` (Task 6) is the
    # path for anything bigger.
    OLLAMA_CONTEXT_LENGTH = "32768";

    OLLAMA_FLASH_ATTENTION = "1";
  };
}
```

- [ ] **Step 4: Import it from the ariane profile**

In `users/kyle/ariane.nix`, add to the `imports` list immediately after `../../home/k9s.nix`:

```nix
    ../../home/llm.nix
```

- [ ] **Step 5: Stage the new files, then dry-check, then apply**

**Staging is not optional and not a tidiness step.** Per `CLAUDE.md`: *"Flakes only see git-tracked files. After creating any new file the build reads, `git add` it or `nix` eval/build won't find it."* `home/llm.nix` is brand new, so without this the switch fails with a `path does not exist` error on a file that is plainly sitting on disk.

Stage explicit paths only — the tree has pre-existing unrelated changes.

```bash
cd ~/nixosdotfiles
git add home/llm.nix tests/llm.test.sh users/kyle/ariane.nix

# Repo convention (CLAUDE.md, "Common commands"): evaluate to a derivation
# path first. Catches syntax and option errors in seconds without building.
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath

home-manager switch --flake .#ariane -b backup
exec fish -l
```

`exec fish -l` is required — `home.sessionVariables` lands in `hm-session-vars.sh`, which an already-running shell has not sourced, so `OLLAMA_HOST` would still read `unset`.

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `7 passed, 0 failed`.

If `mlx default device is gpu` reports `Device(cpu, 0)`, stop and do not proceed to Task 2 — every later benchmark would be measuring the wrong thing. Check that `xcrun -f metal` still resolves and that the process is not running under Rosetta (`sysctl -n sysctl.proc_translated` must print `0`).

- [ ] **Step 7: Commit**

```bash
cd ~/nixosdotfiles
# Already staged in Step 5 (the flake could not have seen home/llm.nix
# otherwise). Re-stated so the paths are explicit and re-running is safe.
git add home/llm.nix tests/llm.test.sh users/kyle/ariane.nix
git status --short   # confirm ONLY these three are staged
git commit -m "Add local LLM stack: Ollama MLX engine + mlx-lm on ariane"
```

---

### Task 2: Models pulled, tags confirmed, short-context baseline measured

**Files:**
- Modify: `tests/llm.test.sh` (append a Task 2 section)
- Create: `docs/local-llm.md`

**Interfaces:**
- Consumes: `ollama` on PATH and `OLLAMA_HOST` from Task 1.
- Produces: two pulled Ollama models, referenced by exact tag in every later task. The agentic tag is **`muse-glimmer:30b-mlx`** (verified to exist in the Ollama library). The coding tag is **not yet verified** and is resolved in Step 1 below; later tasks refer to it as the value recorded in `docs/local-llm.md` under "Resolved model tags".

- [ ] **Step 1: Resolve the coding model's real Ollama tag**

`muse-glimmer:30b-mlx` is confirmed present in the Ollama library. The Qwen3-Coder MLX tag was **not** confirmed during design and must not be guessed.

```bash
ollama serve &>/tmp/ollama-serve.log &
sleep 3
# Ollama has no `search` subcommand; the library is queried over HTTP.
curl -s "https://ollama.com/library/qwen3-coder/tags" | grep -oE 'qwen3-coder:[0-9a-zA-Z._-]+' | sort -u
```

Record the exact tag matching a 30B A3B MLX build. If no `-mlx` variant exists, use the plain `qwen3-coder:30b` tag — on Ollama 0.32.6 the MLX engine is the backend for all Apple Silicon inference, so a non-`-mlx` tag still runs through MLX; the suffix marks a purpose-built conversion, not the only MLX path.

- [ ] **Step 2: Write the failing test**

Append to `tests/llm.test.sh`, before the final `printf`. Replace `qwen3-coder:30b` with the tag resolved in Step 1 if it differs.

```bash
echo
echo "== Task 2: models =="

AGENT_MODEL="muse-glimmer:30b-mlx"
CODER_MODEL="qwen3-coder:30b"

MODELS="$(ollama list 2>/dev/null)"
case "$MODELS" in
  *"$AGENT_MODEL"*) ok "agent model pulled ($AGENT_MODEL)" ;;
  *) bad "agent model pulled ($AGENT_MODEL)" "not in \`ollama list\`" ;;
esac
case "$MODELS" in
  *"$CODER_MODEL"*) ok "coder model pulled ($CODER_MODEL)" ;;
  *) bad "coder model pulled ($CODER_MODEL)" "not in \`ollama list\`" ;;
esac

# The API answers, and answers on loopback.
API="$(curl -s --max-time 10 http://127.0.0.1:11434/v1/models)"
case "$API" in
  *"$AGENT_MODEL"*) ok "/v1/models lists the agent model" ;;
  *) bad "/v1/models lists the agent model" "got: ${API:0:200}" ;;
esac
```

- [ ] **Step 3: Run it to verify the new section fails**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: Task 1's five checks still pass; the three new checks FAIL with `not in \`ollama list\``.

- [ ] **Step 4: Pull both models**

~36 GB total against 269 GB free. This takes a while on a normal connection.

```bash
ollama pull muse-glimmer:30b-mlx
ollama pull qwen3-coder:30b   # or the tag resolved in Step 1
ollama list
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `10 passed, 0 failed`.

- [ ] **Step 6: Measure the short-context baseline**

The spec's `~130 tok/s` and `~25–35 tok/s` are third-party figures. These are ariane's.

```bash
for m in muse-glimmer:30b-mlx qwen3-coder:30b; do
  echo "=== $m ==="
  ollama run "$m" --verbose "Write a Python function that reverses a linked list." 2>&1 | tail -12
done
```

Record `prompt eval rate` and `eval rate` for each.

- [ ] **Step 7: Write the findings doc**

Create `docs/local-llm.md`:

```markdown
# Local LLM on ariane

Runtime: Ollama on its MLX backend. Design rationale and rejected alternatives
live in `docs/superpowers/specs/2026-08-24-local-llm-mlx-design.md`.

## Resolved model tags

| Role | Ollama tag |
|---|---|
| Agentic | `muse-glimmer:30b-mlx` |
| Coding / bulk | `qwen3-coder:30b` |

## Measured on ariane (M4 Pro, 48 GB)

Short context (~50-token prompt), `ollama run --verbose`:

| Model | Prompt eval | Eval (generation) |
|---|---|---|
| muse-glimmer:30b-mlx | _fill from Step 6_ | _fill from Step 6_ |
| qwen3-coder:30b | _fill from Step 6_ | _fill from Step 6_ |

Long-context figures are added by Task 7.

## GPU memory limit

macOS caps GPU-addressable unified memory at ~75% (~36 GB of 48 GB) by
default. With ~19 GB of weights that leaves ~17 GB of KV cache, which agentic
sessions will press. Raise it to 40 GB for a session:

    sudo sysctl iogpu.wired_limit_mb=40960

Needs `sudo` and does not survive reboot, which is why it is documented here
rather than managed by Home Manager.
```

Replace each `_fill from Step 6_` with the real number before committing. A committed placeholder is a plan failure.

- [ ] **Step 8: Commit**

```bash
cd ~/nixosdotfiles
git add tests/llm.test.sh docs/local-llm.md
git commit -m "Pull local models, record short-context baseline on ariane"
```

---

### Task 3: Tool calling verified, and the `/v1` vs `/api/chat` question resolved

The spec's Risk 1 and its single open question. This is the task most likely to fail, and it gates OpenCode entirely — do not start Task 5 until this passes.

**Files:**
- Modify: `tests/llm.test.sh` (append a Task 3 section)
- Modify: `docs/local-llm.md` (append a "Tool calling" section)

**Interfaces:**
- Consumes: both model tags from Task 2, the running server from Task 1.
- Produces: a recorded decision — endpoint `http://127.0.0.1:11434/v1` (OpenAI-compatible) or `http://127.0.0.1:11434/api/chat` (Ollama native) — consumed verbatim by Task 5's OpenCode `baseURL`.

- [ ] **Step 1: Write the failing test**

Append to `tests/llm.test.sh`, before the final `printf`:

```bash
echo
echo "== Task 3: tool calling =="

TOOLS_PAYLOAD='{
  "model": "MODEL_PLACEHOLDER",
  "messages": [
    {"role": "user", "content": "What is the current weather in Asheville, NC? Use the tool."}
  ],
  "tools": [{
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "Get the current weather for a city",
      "parameters": {
        "type": "object",
        "properties": {"city": {"type": "string", "description": "City name"}},
        "required": ["city"]
      }
    }
  }],
  "stream": false
}'

for m in muse-glimmer:30b-mlx qwen3-coder:30b; do
  body="${TOOLS_PAYLOAD/MODEL_PLACEHOLDER/$m}"
  name="$(curl -s --max-time 180 http://127.0.0.1:11434/v1/chat/completions \
    -H 'Content-Type: application/json' -d "$body" \
    | jq -r '.choices[0].message.tool_calls[0].function.name // "none"' 2>/dev/null)"
  check "/v1 tool call: $m" "$name" "get_weather"
done
```

- [ ] **Step 2: Run it to verify it fails or passes**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Unlike a normal TDD step this one may legitimately pass immediately — the models and server already exist, and this test probes behaviour rather than absent code. Both outcomes are informative:

- **Both `get_weather`** → `/v1` works. Record `/v1` as the endpoint and skip to Step 5.
- **Either `none`** → continue to Step 3.

- [ ] **Step 3: Try Ollama's native endpoint**

The OpenAI compatibility layer omits `tool_choice`, `logprobs`, and `logit_bias`, and parses tool-call delimiters less forgivingly. The native endpoint is the documented out.

```bash
curl -s --max-time 180 http://127.0.0.1:11434/api/chat -H 'Content-Type: application/json' -d '{
  "model": "muse-glimmer:30b-mlx",
  "messages": [{"role": "user", "content": "What is the current weather in Asheville, NC? Use the tool."}],
  "tools": [{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
  "stream": false
}' | jq '.message.tool_calls'
```

Expected on success: an array whose first element has `.function.name == "get_weather"`.

- [ ] **Step 4: If both endpoints fail, raise the context and retry**

A truncated system prompt drops the tool definitions before the model ever sees them, which presents as "the model just answers in prose". Confirm this is not the cause before concluding the model cannot tool-call:

```bash
OLLAMA_CONTEXT_LENGTH=65536 ollama serve &>/tmp/ollama-serve.log &
sleep 3
# re-run Step 3
```

If tool calls still fail on both endpoints and both models, stop and report. The remaining mitigations — OpenCode's `toolParser` array and a chat-template override — are Task 5 concerns and should not be attempted blind here.

- [ ] **Step 5: Record the decision**

Append to `docs/local-llm.md`:

```markdown
## Tool calling

Endpoint in use: `http://127.0.0.1:11434/v1` — or `/api/chat`, whichever passed.

Verified with a single-function `get_weather` schema against both models on
_date_. Re-run with `bash tests/llm.test.sh`.

Known constraint: Ollama's OpenAI compatibility layer omits `tool_choice`,
`logprobs`, and `logit_bias`. If OpenCode ever needs to force a specific tool,
that is the reason it will not work over `/v1`.
```

Replace the endpoint line and `_date_` with real values.

- [ ] **Step 6: Commit**

```bash
cd ~/nixosdotfiles
git add tests/llm.test.sh docs/local-llm.md
git commit -m "Verify local tool calling, pin the OpenCode endpoint choice"
```

---

### Task 4: The `llm` command

On-demand serving, per the spec's explicit rejection of an always-on agent.

**Files:**
- Modify: `home/llm.nix` (add the `llm` script and fish abbreviations)
- Modify: `tests/llm.test.sh` (append a Task 4 section)

**Interfaces:**
- Consumes: model tags from Task 2.
- Produces: an `llm` binary on PATH with subcommands `agent`, `coder`, `stop`, `status`, `bench`. Task 6 adds `long` to the same dispatch.

- [ ] **Step 1: Write the failing test**

Append to `tests/llm.test.sh`, before the final `printf`:

```bash
echo
echo "== Task 4: llm command =="
have llm

LLM_HELP="$(llm 2>&1 || true)"
for sub in agent coder stop status bench; do
  case "$LLM_HELP" in
    *"$sub"*) ok "llm usage mentions '$sub'" ;;
    *) bad "llm usage mentions '$sub'" "usage was: ${LLM_HELP:0:200}" ;;
  esac
done

# `llm stop` must be idempotent -- calling it with nothing running is the
# normal case after a reboot and must not error.
llm stop >/dev/null 2>&1
check "llm stop is idempotent" "$?" "0"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `llm on PATH: not found`, five `usage mentions` failures, and the idempotency check failing.

- [ ] **Step 3: Add the script to `home/llm.nix`**

Insert into the existing `let` block, after the `mlxPython` binding:

```nix
  agentModel = "muse-glimmer:30b-mlx";
  coderModel = "qwen3-coder:30b";

  # On-demand, deliberately: both models resident is ~36 GB of 48 GB, so a
  # launchd agent holding one warm was rejected in the spec. `llm stop` is the
  # other half of that bargain and must actually free the memory.
  llm = pkgs.writeShellScriptBin "llm" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath (with pkgs; [ ollama curl coreutils ])}:$PATH"
    export OLLAMA_HOST="127.0.0.1:11434"

    log="''${TMPDIR:-/tmp}/ollama-serve.log"

    serve_if_needed() {
      if curl -sf --max-time 2 "http://$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
        return 0
      fi
      echo "starting ollama (log: $log)" >&2
      nohup ollama serve >"$log" 2>&1 &
      for _ in $(seq 1 30); do
        sleep 1
        curl -sf --max-time 2 "http://$OLLAMA_HOST/api/tags" >/dev/null 2>&1 && return 0
      done
      echo "ollama did not come up within 30s; see $log" >&2
      return 1
    }

    # Load one model and unload the other, so the two never co-reside.
    # keep_alive: -1 pins the wanted model; 0 evicts the unwanted one.
    load_only() {
      local want="$1" drop="$2"
      serve_if_needed
      curl -sf "http://$OLLAMA_HOST/api/generate" \
        -d "{\"model\":\"$drop\",\"keep_alive\":0}" >/dev/null 2>&1 || true
      echo "loading $want" >&2
      curl -sf "http://$OLLAMA_HOST/api/generate" \
        -d "{\"model\":\"$want\",\"keep_alive\":-1}" >/dev/null
      echo "$want ready on http://$OLLAMA_HOST" >&2
    }

    case "''${1-}" in
      agent) load_only ${lib.escapeShellArg agentModel} ${lib.escapeShellArg coderModel} ;;
      coder) load_only ${lib.escapeShellArg coderModel} ${lib.escapeShellArg agentModel} ;;
      status)
        if curl -sf --max-time 2 "http://$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
          ollama ps
        else
          echo "ollama not running"
        fi
        ;;
      stop)
        # Idempotent by contract: tests/llm.test.sh asserts exit 0 with
        # nothing running, which is the normal state after a reboot.
        #
        # /usr/bin/pkill by absolute path, NOT via makeBinPath: nixpkgs'
        # `procps` is Linux-only (meta.platforms has no darwin), so adding it
        # to the closure would fail the build on the one machine this module
        # targets. macOS ships its own pkill and this module is darwin-gated.
        /usr/bin/pkill -f 'ollama serve' 2>/dev/null || true
        echo "stopped" >&2
        ;;
      bench)
        serve_if_needed
        for m in ${lib.escapeShellArg agentModel} ${lib.escapeShellArg coderModel}; do
          echo "=== $m ==="
          ollama run "$m" --verbose \
            "Write a Python function that reverses a linked list." 2>&1 | tail -12
        done
        ;;
      *)
        cat >&2 <<'USAGE'
    usage: llm <command>

      agent    serve muse-glimmer:30b-mlx (tool use, long-horizon tasks)
      coder    serve qwen3-coder:30b      (fast bulk work, completions)
      status   show what is currently loaded
      stop     tear down the server and free the memory
      bench    short-context tok/s for both models
    USAGE
        exit 1
        ;;
    esac
  '';
```

Then add `llm` to the package list:

```nix
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.ollama
    mlxPython
    llm
  ];
```

- [ ] **Step 4: Apply**

```bash
cd ~/nixosdotfiles
# Dry-check first (CLAUDE.md, "Common commands") -- evaluates to a
# derivation path in seconds and catches option errors before a build.
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
home-manager switch --flake .#ariane -b backup
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: all Task 1–4 checks pass, `19 passed, 0 failed`.

- [ ] **Step 6: Verify the memory actually comes back**

The whole justification for on-demand is that `stop` frees ~19 GB. Confirm it, rather than assuming.

```bash
llm agent
ollama ps                      # should show the model with a size
llm stop
sleep 2
ollama ps 2>&1 || echo "server down"
pgrep -f 'ollama serve' || echo "no ollama process"
```

Expected: `ollama ps` lists the model while loaded; after `stop`, no process remains.

- [ ] **Step 7: Commit**

```bash
cd ~/nixosdotfiles
git add home/llm.nix tests/llm.test.sh
git commit -m "Add on-demand llm command for local model serving"
```

---

### Task 5: OpenCode wired to the local provider, PHI hardened

**Files:**
- Modify: `home/llm.nix` (add the `xdg.configFile` block)
- Modify: `tests/llm.test.sh` (append a Task 5 section)

**Interfaces:**
- Consumes: the endpoint decided in Task 3, model tags from Task 2.
- Produces: `~/.config/opencode/opencode.json`, Home Manager–managed and therefore read-only.

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
    "$(jq -r '.provider.ollama.options.baseURL' "$CFG")" \
    "http://127.0.0.1:11434/v1"

  # Zero cloud providers. The whole PHI case rests on this one assertion.
  check "only the local provider is configured" \
    "$(jq -r '.provider | keys | join(",")' "$CFG")" "ollama"

  # Managed by Home Manager means a store symlink, which means it cannot be
  # edited in place to quietly add a cloud provider later.
  [ -L "$CFG" ] && ok "config is a nix store symlink" \
                || bad "config is a nix store symlink" "it is a plain file"
fi

# Nothing may listen off-loopback. This is the audit, not a formality.
OFFLOOP="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
  | grep -Ei 'ollama|llama' | grep -v '127\.0\.0\.1' | wc -l | tr -d ' ')"
check "no off-loopback llm listeners" "$OFFLOOP" "0"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `opencode config exists` FAILs; the jq-dependent checks are skipped by the `if`. The `lsof` check may already pass — that is fine, it is a regression guard.

- [ ] **Step 3: Add the config to `home/llm.nix`**

Append inside the top-level attribute set, after `home.sessionVariables`. If Task 3 selected `/api/chat`, change `baseURL` accordingly and update the test in Step 1 to match.

```nix
  # OpenCode's local profile. Written through xdg.configFile so it lands as a
  # read-only store symlink -- a cloud provider cannot be added by an
  # accidental in-place edit, which tests/llm.test.sh asserts.
  #
  # `provider` deliberately contains exactly one entry. Every PHI guarantee in
  # the spec reduces to that fact plus the loopback baseURL.
  xdg.configFile."opencode/opencode.json" = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      share = "disabled";
      autoupdate = false;
      provider = {
        ollama = {
          npm = "@ai-sdk/openai-compatible";
          name = "Ollama (local, MLX)";
          options.baseURL = "http://127.0.0.1:11434/v1";
          models = {
            "muse-glimmer:30b-mlx" = {
              name = "Muse Glimmer 30B — agentic";
              tools = true;
            };
            "qwen3-coder:30b" = {
              name = "Qwen3-Coder 30B A3B — coding";
              tools = true;
            };
          };
        };
      };
    };
  };
```

- [ ] **Step 4: Apply**

```bash
cd ~/nixosdotfiles
# Dry-check first (CLAUDE.md, "Common commands") -- evaluates to a
# derivation path in seconds and catches option errors before a build.
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
home-manager switch --flake .#ariane -b backup
```

If activation fails with a clobber error on `~/.config/opencode/opencode.json`, an unmanaged file is in the way. Inspect it, then move it aside — do not delete without looking:

```bash
cat ~/.config/opencode/opencode.json
mv ~/.config/opencode/opencode.json ~/.config/opencode/opencode.json.pre-nix
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `26 passed, 0 failed`.

- [ ] **Step 6: Audit OpenCode's own network behaviour**

The config disables sharing and autoupdate, but that is OpenCode's word for it. Verify no unexpected outbound connections during a local-only run:

```bash
llm coder
cd /tmp && rm -rf llm-scratch && mkdir llm-scratch && cd llm-scratch
git init -q && echo 'def add(a, b): return a - b' > calc.py && git add -A
git -c user.email=kmello@broadriverrehab.com -c user.name=kyle commit -qm init

# In a second terminal, watch for non-loopback connections from opencode:
#   lsof -nP -iTCP -a -c opencode -r2 | grep -v 127.0.0.1
opencode run --model ollama/qwen3-coder:30b "Fix the bug in calc.py"
```

Record in `docs/local-llm.md` whether anything appeared. Anything other than loopback is a finding to report, not to wave through.

- [ ] **Step 7: Commit**

```bash
cd ~/nixosdotfiles
git add home/llm.nix tests/llm.test.sh
git commit -m "Wire OpenCode to the local provider, loopback-only, no cloud fallback"
```

---

### Task 6: llama.cpp escape hatch for prompts past 60K

**Files:**
- Modify: `flake.nix` (inputs block ~line 5–31, outputs destructure ~line 35, overlays list ~line 37–46)
- Modify: `home/llm.nix` (add `llama-cpp` to packages, add the `long` subcommand)
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
    # for prompts past ~60K tokens, where MLX's long-context penalty (~50% of
    # llama.cpp+flash-attention on token generation) makes Ollama the wrong
    # engine. Muse Glimmer support landed in llama.cpp b10353; the pinned
    # nixos-unstable ships b10273, which is too old. A full `nix flake update`
    # would fix it and rebuild the world -- this pins one package instead.
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
nix eval --raw .#legacyPackages.aarch64-darwin.llama-cpp.version 2>/dev/null \
  || nix eval --raw "$(nix flake metadata --json | jq -r '.locks.nodes["nixpkgs-llama"].locked | "github:\(.owner)/\(.repo)/\(.rev)"')#llama-cpp.version"
```

Expected: a number ≥ 10353. If it is lower, the branch regressed — pin an explicit known-good rev rather than the branch name.

- [ ] **Step 5: Add `llama-cpp` and the `long` subcommand to `home/llm.nix`**

Add to the package list:

```nix
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.ollama
    pkgs.llama-cpp
    mlxPython
    llm
  ];
```

In the `llm` script's `case`, add a `long` branch immediately before the `*)` default:

```bash
      long)
        gguf="''${2-}"
        if [ -z "$gguf" ] || [ ! -f "$gguf" ]; then
          echo "usage: llm long <path-to.gguf>" >&2
          echo "the escape hatch for prompts past ~60K tokens, where MLX" >&2
          echo "runs at roughly half llama.cpp+flash-attention on decode." >&2
          exit 1
        fi
        exec llama-server \
          --model "$gguf" \
          --host 127.0.0.1 --port 8080 \
          --ctx-size 131072 \
          --flash-attn \
          --n-gpu-layers 99 \
          --jinja
        ;;
```

Add `pkgs.llama-cpp` to the script's `makeBinPath` list so `llama-server` resolves inside it:

```nix
    export PATH="${lib.makeBinPath (with pkgs; [ ollama llama-cpp curl coreutils ])}:$PATH"
```

And add `long` to the usage heredoc:

```
      long     serve a GGUF via llama.cpp for >60K-token prompts
```

- [ ] **Step 6: Apply**

```bash
cd ~/nixosdotfiles
# Dry-check first (CLAUDE.md, "Common commands") -- evaluates to a
# derivation path in seconds and catches option errors before a build.
nix eval .#legacyPackages.aarch64-darwin.homeConfigurations.ariane.activationPackage.drvPath
home-manager switch --flake .#ariane -b backup
```

`llama-cpp` from a different nixpkgs may not be in the binary cache and can take several minutes to compile against Metal. That is expected, not a failure.

- [ ] **Step 7: Run the test to verify it passes**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `28 passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
cd ~/nixosdotfiles
git add flake.nix flake.lock home/llm.nix tests/llm.test.sh
git commit -m "Pin llama-cpp >= b10353 as the long-context escape hatch"
```

`flake.lock` is staged here deliberately despite its pre-existing dirty state. Check `git diff --cached flake.lock` first and confirm the only change is the added `nixpkgs-llama` node — if the pre-existing delete/add churn is also staged, unstage and resolve that separately before committing.

---

### Task 7: Long-context measurement and the end-to-end agent run

Closes Verification step 5 in the spec: the "which model when" rule gets written from ariane's numbers, not from blog posts.

**Files:**
- Modify: `docs/local-llm.md` (long-context table, routing rule)
- Modify: `docs/superpowers/specs/2026-08-24-local-llm-mlx-design.md` (status line)

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: no code. A documented routing rule and a status change.

- [ ] **Step 1: Raise the GPU memory limit**

```bash
sudo sysctl iogpu.wired_limit_mb=40960
sysctl iogpu.wired_limit_mb
```

Expected: `iogpu.wired_limit_mb: 40960`. This does not survive reboot by design.

- [ ] **Step 2: Build a ~40K-token prompt**

The spec's central open risk is a third-party report of 3.5 minutes to first token at 40K. Measure it here.

```bash
cd /tmp
# ~40K tokens at roughly 4 chars/token = ~160KB of real source text.
find /nix/store -maxdepth 4 -name '*.py' -size +4k 2>/dev/null | head -40 \
  | xargs cat 2>/dev/null | head -c 160000 > big-prompt.txt
wc -c big-prompt.txt
```

- [ ] **Step 3: Measure time-to-first-token at 40K on both engines**

```bash
llm agent
for m in muse-glimmer:30b-mlx qwen3-coder:30b; do
  echo "=== $m @ 40K ==="
  { printf 'Summarize what this code does in two sentences:\n\n'; cat /tmp/big-prompt.txt; } \
    | OLLAMA_CONTEXT_LENGTH=65536 ollama run "$m" --verbose 2>&1 | tail -12
done
```

Record `prompt eval rate`, `eval rate`, and total duration for each.

- [ ] **Step 4: Record the routing rule**

Append to `docs/local-llm.md`:

```markdown
## Measured: long context (~40K tokens)

| Model | Prompt eval | Eval | Total |
|---|---|---|---|
| muse-glimmer:30b-mlx | _fill_ | _fill_ | _fill_ |
| qwen3-coder:30b | _fill_ | _fill_ | _fill_ |

## Which model when

Written from the numbers above, not from vendor claims.

- `llm coder` — bulk work, completions, anything where throughput matters.
- `llm agent` — multi-step tool use, where recovering from a failed call
  matters more than tok/s.
- `llm long <gguf>` — prompts past the crossover point measured above, where
  llama.cpp+flash-attention overtakes MLX.
```

Replace every `_fill_` with a real number. State the crossover point explicitly if the 40K measurement shows one, and say plainly if it does not.

- [ ] **Step 5: Run the full end-to-end agent task**

Not a toy. A multi-file change requiring several tool calls in sequence:

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

llm agent
opencode run --model ollama/muse-glimmer:30b-mlx \
  "Add a tests/ directory with pytest tests for total_value, including an empty-list case and a case with a missing 'qty' key. Then fix total_value to handle the missing key without raising."
```

Record: did it complete, how many tool calls, how long, and did the result actually run (`python -m pytest tests/`)?

- [ ] **Step 6: Run the full test suite one final time**

```bash
cd ~/nixosdotfiles && bash tests/llm.test.sh
```

Expected: `28 passed, 0 failed`.

- [ ] **Step 7: Update the spec status**

In `docs/superpowers/specs/2026-08-24-local-llm-mlx-design.md`, change:

```
**Status:** Design approved, pending implementation plan
```

to:

```
**Status:** Implemented 2026-08-__. Measured results in `docs/local-llm.md`.
```

Fill the real date.

- [ ] **Step 8: Commit**

```bash
cd ~/nixosdotfiles
git add docs/local-llm.md docs/superpowers/specs/2026-08-24-local-llm-mlx-design.md
git commit -m "Record measured local LLM performance and the model routing rule"
```

---

## Self-review notes

**Spec coverage.** Every spec section maps to a task: Component 1 (Ollama MLX) → Task 1–2; Component 2 (llama.cpp hatch) → Task 6; Component 3 (mlx-lm side channel) → Task 1; Component 4 (models) → Task 2; Component 5 (OpenCode) → Task 5; Component 6 (`home/llm.nix` runtime) → Task 4; Component 7 (memory headroom) → Task 2 Step 7 doc + Task 7 Step 1. PHI hardening → Task 5. All five Verification steps → Tasks 1, 3, 5, 7. Risk 1 → Task 3. Risk 2 → Task 6. Risk 3 → Task 3 Step 3. The spec's open question → Task 3, resolved empirically.

**Two deliberate deviations from the spec, both narrowing scope:**

- The spec listed `llm bench` as running `mlx_lm.generate` against HF MLX repos as a raw-runtime baseline. Task 4 implements `bench` against Ollama only. The MLX baseline would need a second ~19 GB copy of the weights in `~/.cache/huggingface` for a number that does not change any decision. `mlx_lm.generate` is still installed and the comparison remains available by hand.
- The spec named `llm long` as a plain subcommand. Task 6 requires an explicit GGUF path argument, because no GGUF is downloaded anywhere in this plan — Ollama's store is not GGUF-addressable for `llama-server`. Acquiring one is left out rather than half-specified.

**Not verified during planning, and flagged in-task rather than guessed:** the Ollama tag for Qwen3-Coder-30B-A3B (Task 2 Step 1 resolves it), and whether `nixpkgs-unstable` still carries llama.cpp ≥ b10353 at execution time (Task 6 Step 4 checks).
