# Local LLM on ariane: MLX runtime + OpenCode harness

**Date:** 2026-08-24
**Status:** Design approved, pending implementation plan

## Goal

Run capable models entirely on ariane, driven by a real agent harness, for four
overlapping uses Kyle named:

1. **PHI / confidential work** — resident records, contracts, anything
   HIPAA-adjacent that must not leave the machine.
2. **Offline fallback** — coding on a plane, bad hotel wifi, or an API outage.
3. **Cheap bulk work** — grunt tasks not worth Claude tokens.
4. **Agentic coding and tinkering** — real tool-using agent loops, with freedom
   to swap models.

Two models, per the original ask: a best-available **coding** model and a
best-available **agentic** model.

## Non-goals

- **Not** replacing Claude Code. On 48 GB this is a second-tier tool for the
  four cases above, not a daily driver.
- **Not** an always-on service. Explicitly chosen: on-demand start/stop, so a
  ~19 GB resident model isn't permanently spoken for.
- **Not** imperative installs. Everything reproducible lives in
  `~/nixosdotfiles`. Model weights are the deliberate exception — too large and
  too churn-prone for the Nix store.
- **Not** fine-tuning, training, or serving to other machines.

## Current state

Measured on ariane, 2026-08-22 through 2026-08-24:

| Fact | Value |
|---|---|
| Machine | MacBook Pro, `Mac16,7`, Apple M4 Pro |
| Cores | 14 (10 performance, 4 efficiency) |
| Unified memory | 48 GB LPDDR5 (Hynix) |
| Memory bandwidth | 273 GB/s (M4 Pro spec) |
| Free disk | 269 GB |
| macOS | 26.5.2 (build 25F84) |
| Xcode / Metal | Xcode 26.0.1, SDK 26.0, `metal` compiler present |
| `iogpu.wired_limit_mb` | `0` — unset, so default ≈ 75% ≈ 36 GB GPU-addressable |
| Inference engines installed | **none** |
| `opencode` on PATH | 1.18.18, via `~/.nix-profile` |

Relevant nixpkgs state (user's pinned `nixos-unstable` unless noted):

| Package | Version | Note |
|---|---|---|
| `ollama` | 0.32.6 | aarch64-darwin supported |
| `python3Packages.mlx` | 0.32.0 | |
| `python3Packages.mlx-lm` | 0.31.3 | `meta.broken = false`, aarch64-darwin in platforms |
| `llama-cpp` | b10273 | **too old** — see Risk 2 |
| `llama-cpp` (unstable HEAD) | b10408 | sufficient |
| `opencode` | 1.18.13 | older than what's installed; harmless |
| `uv` | 0.12.1 | |
| `python3Packages.huggingface-hub` | 1.26.0 | provides the download library |

`nix build --dry-run nixpkgs#python3Packages.mlx-lm` reports **"these 24 paths
will be fetched (49.8 MiB download, 300.8 MiB unpacked)"** — zero local
compilation. MLX is effectively free to add.

**Not in nixpkgs:** `vllm-mlx`, `vmlx`, `sglang`, and the standalone `hf` CLI.

Repo wiring: `flake.nix` → `homeConfigurations.ariane` → `users/kyle/ariane.nix`,
which imports a flat list from `home/` plus `home/packages/{base,dev,misc}.nix`.
Overlays auto-discover from `overlays/*.nix` via `overlays/default.nix`.

**Repo is dirty as of writing** — `claude/local/ariane.json`,
`claude/settings.json`, `nvim/lazy-lock.json` modified and `flake.lock` in a
delete/add state, all pre-existing and unrelated to this work. The spec commit
must touch only the spec file.

## The runtime decision

The original design used llama.cpp. Kyle asked for MLX. These are separate,
competing runtimes — llama.cpp has hand-written GGML Metal kernels, MLX is
Apple's own array framework with its own format. There is no "llama.cpp on MLX."

MLX wins decisively on this hardware for MoE models: **~130 tok/s vs ~43 tok/s**
for Qwen3-Coder-30B-A3B on an M4 Pro. Ollama found this convincing enough to
remove the llama.cpp Metal backend entirely in v0.19 (2026-03-30), reporting 93%
faster decode and 57% faster prefill.

Two honest qualifications:

- The much-publicised MLX gains from Apple's **Neural Accelerators are M5-only**.
  The M4 Pro gets the MoE decode win and not that one.
- **MLX degrades badly on long context**, which is exactly the agentic workload.
  Plain `mlx_lm.server` runs ~50% of llama.cpp+flash-attention's token-gen speed
  on long context; one report measures 3.5 minutes to first token on a
  40K-token prompt; Metal command buffers can exhaust past 80K. It is
  competitive only to roughly 60K prompt tokens.

The resolution is to use MLX **through Ollama rather than raw `mlx_lm.server`**,
and to keep llama.cpp installed as a long-context escape hatch.

## Architecture

```
  OpenCode  (harness, MIT, already installed)
      │
      │  OpenAI-compatible /v1  → 127.0.0.1 only
      │
      ├── Ollama 0.32.6, MLX engine          ← primary, both models
      │     • snapshot / checkpoint caching
      │     • muse-glimmer:30b-mlx (DFlash)
      │     • qwen3-coder-30b-a3b (MLX 4-bit)
      │
      └── llama-server (llama.cpp, pinned)   ← escape hatch, prompts >60K
            • flash attention
            • GGUF weights

  mlx-lm 0.31.3  ← side channel: benchmarking, quantizing, raw-MLX comparison
                   (not in the agent path)
```

### Component 1 — Engine: Ollama 0.32.6 on its MLX backend

Chosen over raw `mlx_lm.server` for one specific reason: **snapshot caching**.
Agent loops are dominated by prompt processing — every tool call resends the
whole transcript, so the model reprocesses the same context dozens of times per
task. Ollama's MLX engine stores reusable model state at strategic checkpoints
and processes only the delta on the next request. `mlx_lm.server` has no
equivalent, and without it MLX's long-context weakness lands directly on the
agentic use case.

Secondary reasons: it's in nixpkgs at 0.32.6 with aarch64-darwin support, so it
stays declarative; and `muse-glimmer:30b-mlx` is a first-class Ollama model with
DFlash speculative decoding already wired up.

### Component 2 — Engine: llama.cpp, as the >60K escape hatch

Kept, not discarded. Where MLX degrades, llama.cpp with flash attention is
roughly 2× faster on token generation. Two engines, both declarative, chosen per
task is the correct answer here rather than pretending one runtime wins
everywhere.

Requires the version fix in Risk 2.

### Component 3 — `mlx-lm` 0.31.3, side channel

Not in the agent path. Provides `mlx_lm.generate` for benchmarking,
`mlx_lm.convert` for quantizing models Ollama doesn't carry, and a raw-MLX
baseline to check Ollama's overhead against. Costs 49.8 MiB of prebuilt binaries.

### Component 4 — Models

| Role | Model | Format | Size | Expected |
|---|---|---|---|---|
| Coding / bulk | Qwen3-Coder-30B-A3B | MLX 4-bit | ~19 GB | ~130 tok/s |
| Agentic | `muse-glimmer:30b-mlx` | Ollama MLX + DFlash | ~17 GB | ~25–35 tok/s |

**Qwen3-Coder-30B-A3B** is MoE with ~3.3B active parameters — that is why it is
6–8× faster than its size suggests, and why it is the one that benefits most
from MLX. 256K context. This is the bulk-work, completion, and
cheap-grunt-task horse.

**Muse Glimmer 30B** (Meta, Apache 2.0, released 2026-08-10) is the agentic pick
because it is explicitly trained for tool use, long-horizon tasks, and failure
recovery — the failure modes that break local agents. It beats Qwen3.6-27B by 13
points on MCP tool use. 131K context, multimodal. It is *dense* 30B, so it is
the slow one; the bundled DFlash drafter (1.5–1.8× on Apple Silicon) is what
makes it tolerable.

Weights live in Ollama's own store (`~/.ollama`), outside the Nix store. Disk
cost ~36 GB against 269 GB free.

### Component 5 — Harness: OpenCode

Already installed at 1.18.18. MIT, provider-agnostic, in nixpkgs, and the
best-documented local-provider path. Configured via
`~/.config/opencode/opencode.json` with an `@ai-sdk/openai-compatible` provider
pointing at the local endpoint, one model entry per served model.

### Component 6 — Runtime: on-demand, via `home/llm.nix`

A new Home Manager module defining fish functions — shell is fish, managed by
`home/fish.nix`:

- `llm coder` — serve the Qwen coder model
- `llm agent` — serve Muse Glimmer
- `llm long` — start `llama-server` for >60K-context work
- `llm stop` — tear down, free the RAM
- `llm bench` — timing run: Ollama's own `--verbose` stats for the served
  models, plus `mlx_lm.generate` against the equivalent HF MLX repos as a
  raw-runtime baseline. Note these read different copies of the weights —
  Ollama's store vs `~/.cache/huggingface` — so the baseline costs extra disk.

Imported from `users/kyle/ariane.nix`. Declarative; no launchd agent.

### Component 7 — Memory headroom

At the current default wired limit of ~36 GB, a 19 GB model leaves ~17 GB for KV
cache. That is workable but agentic sessions will press it — a comparable report
on 32 GB (20 GB weights, 12 GB KV) pushed into swap.

Plan on raising it to ~40 GB:

```
sudo sysctl iogpu.wired_limit_mb=40960
```

This needs `sudo` and does not survive reboot, so it **cannot** be Home
Manager–managed. It goes in the module's comment block and in `docs/` as a
documented one-liner, matching how `home/darwin.nix` already documents the
`chsh` and `/etc/shells` steps.

## PHI hardening

Non-negotiable given use case 1:

- Bind loopback only (`127.0.0.1`). Never `0.0.0.0`.
- `OLLAMA_HOST=127.0.0.1` set in the module, explicitly, not relied on as default.
- The OpenCode local profile carries **zero** cloud providers.
- `"share": "disabled"` in the OpenCode config.
- Audit and disable OpenCode autoupdate and any telemetry; record what was found.
- Verify with `lsof -nP -iTCP -sTCP:LISTEN | grep -E 'ollama|llama'` that nothing
  is listening off-loopback.

## Verification

No step counts as done without its output captured:

1. `ollama serve` starts; `curl 127.0.0.1:11434/v1/models` lists both models.
2. **Tool-calling smoke test per model** — a `/v1/chat/completions` call with a
   `tools` array, asserting a well-formed `tool_calls` response. This is the
   step most likely to fail; see Risk 1.
3. OpenCode completes an end-to-end multi-tool task in a scratch repo, with
   each model.
4. `lsof` listener audit per PHI section above.
5. **Measured tok/s and time-to-first-token for both models**, at ~4K and at
   ~40K context, recorded in the plan. Every speed figure in this spec is from
   third-party benchmarks, not from ariane. The "which model when" rule gets
   rewritten from Kyle's own numbers.

## Risks

1. **Tool calling with local models is genuinely flaky.** This is the most
   likely place the work stalls. OpenCode was designed against large cloud
   models; local models understand the OpenAI tool schema partially and
   unreliably. Known failure modes: models emitting multiple tool calls and
   receiving one result; servers failing to parse tool-call delimiters that
   tokenize as multiple sub-tokens. Mitigations available: OpenCode's
   `toolParser` array, a chat-template override, or Ollama's native `/api/chat`
   instead of the OpenAI shim. Budget real time for this.

2. **Pinned `llama-cpp` is b10273; Muse Glimmer needs b10353+.** Only affects
   the escape-hatch engine, not the Ollama path. Fix is a second pinned nixpkgs
   input plus a one-line overlay for `llama-cpp` alone — *not* a whole-tree
   `nix flake update`, which would rebuild broadly.

3. **Ollama's OpenAI compatibility layer omits fields** — `tool_choice`,
   `logprobs`, `logit_bias`. Usually survivable for OpenCode; interacts badly
   with Risk 1 if tool selection needs forcing. Native `/api/chat` is the out.

4. **Agentic loops are token-hungry and Muse Glimmer is dense.** At ~25–35 tok/s
   expect minutes per task, not seconds. This is real but not a Claude Code
   substitute, and the plan should not pretend otherwise.

5. **48 GB is the binding constraint.** Both models resident simultaneously
   (36 GB) leaves nothing. On-demand single-model serving is not a preference
   here, it's a requirement.

6. **Muse Glimmer is two weeks old.** Template and tooling rough edges are
   likely across the whole stack.

## Rejected alternatives

- **Raw `mlx_lm.server`** — no snapshot/prefix caching, which is the one thing
  the agentic use case most needs. Kept as a side channel only.
- **llama.cpp as primary** — 3× slower than MLX on this chip for the MoE coding
  model. Demoted to escape hatch rather than dropped, because it wins past 60K.
- **LM Studio** — best-in-class MLX GUI and it *is* in nixpkgs (0.4.19-2), but
  it's a GUI app driving an imperative model store. Fails the declarative
  requirement.
- **DeepSeek Harness (`dsh`)** — the other harness Kyle named. Rejected: it is a
  developer preview with explicitly unstable plugin contracts, it is not in
  nixpkgs, and its headline feature is calling Claude Code / Codex as subagents,
  which is precisely the cloud round-trip the PHI use case must avoid. Revisit
  when it leaves preview.
- **`vllm-mlx` / `vMLX`** — *deferred, not rejected.* Both are better MLX
  agentic servers than Ollama: paged KV cache, prefix caching, SSD-tiered KV
  cache, and an Anthropic `/v1/messages` endpoint that Claude Code itself could
  point at. Neither is in nixpkgs, so both need packaging work. Phase 2 if
  Ollama's snapshot caching doesn't hold up under Verification step 5.
- **Qwen3-Coder-Next 80B-A3B** — the better coding model, and it does not fit.
  4-bit is 42–46 GB against 48 GB of unified memory, leaving no room for KV
  cache. Q3 (~32 GB) fits only as the sole resident process with the wired limit
  raised. Not worth the constraint at this stage.
- **Always-on launchd agent** — explicitly declined; a ~19 GB permanent
  reservation on a 48 GB machine is too expensive.

## Open question for implementation

Whether OpenCode talks to Ollama through the OpenAI-compatible `/v1` endpoint or
Ollama's native `/api/chat`. `/v1` is the cleaner config and keeps the escape
hatch drop-in compatible; `/api/chat` has better tool-call fidelity. Resolve
empirically at Verification step 2 rather than guessing now.

---

# Amendment — 2026-08-24, after Task 1 failed

The original design above is **superseded in its runtime choice**. Recorded
rather than rewritten, because the reasoning that led here is the useful part.

## What broke

Task 1 asserted MLX was on the GPU. It was not, and the cause is structural:

| Component | Finding | Evidence |
|---|---|---|
| `python3Packages.mlx` (nixpkgs) | Built `-DMLX_BUILD_METAL:BOOL=FALSE` | `mx.metal.is_available()` → `False`, `default_device` → `Device(cpu, 0)` |
| `ollama` (nixpkgs, 0.32.13 installed) | Built `OLLAMA_MLX_BACKENDS=""` | `$out/lib/ollama` holds only `llama-quantize` + `llama-server`; no MLX libs |

Nix's build sandbox cannot reach Apple's closed-source `metal` compiler, so
nixpkgs ships MLX with the Metal backend compiled out. Ollama's nixpkgs build
disables its MLX backends for the same reason.

Ollama still links `Metal.framework`, so GPU inference via llama.cpp works. It
is **MLX specifically** that is absent — and MLX-engine snapshot caching was
the entire reason Component 1 chose Ollama. That rationale is void.

Note also: the installed Ollama is **0.32.13** from the flake's own nixpkgs,
not the 0.32.6 the `nixpkgs#` registry reported and that the table above cites.

## The replacement, chosen by Kyle from four options

**MLX from Apple's PyPI wheels, in a `uv`-managed venv.** Verified working on
ariane before adopting:

```
default_device: Device(gpu, 0)     metal available: True
device: Apple M4 Pro               max recommended working set: 37.4 GiB
```

`mlx-metal` is a **separate wheel** (0.32.1) — that is the piece nixpkgs
strips. The 37.4 GiB working set independently confirms this spec's ~36 GB
memory estimate.

### Engine: `vllm-mlx` 0.4.1, not `mlx_lm.server`

The uv decision removes the packaging obstacle that made vllm-mlx "phase 2" in
the Rejected Alternatives above. It is now the primary engine. Verified live on
ariane serving `mlx-community/Llama-3.2-1B-Instruct-4bit`: bound to
`127.0.0.1`, ready in ~26 s.

It supplies, as real flags, everything this spec previously listed as a gap:

- `--enable-prefix-cache`, `--use-paged-cache`, `--prefix-cache-size` — the
  agentic-loop fix. Live and instrumented: `/v1/cache/stats` returns
  hits/misses/stores/evictions/hit_ratio.
- `--ssd-cache-dir`, `--ssd-cache-max-gb` — SSD-tiered KV cache.
- `--kv-cache-quantization --kv-cache-quantization-bits {4,8}` — directly
  attacks the 48 GB headroom problem in Component 7.
- `--enable-auto-tool-choice --tool-call-parser {…,qwen3_coder,…}` — a parser
  purpose-built for the coding model. This is the strongest available answer
  to Risk 1.
- `--auto-unload-idle-seconds` — the "always-on with idle unload" option
  originally declined for lack of an implementation.
- `--models-config` + `--lazy-load-model` — lazy multi-model serving, which
  replaces the `llm coder` / `llm agent` load-and-evict dance.
- `--offline`, `--api-key`, `--host` — PHI hardening.

**`/v1/messages` (Anthropic) returns HTTP 200.** Claude Code itself can point
at this server, which no previous option offered. `/v1/mcp/{tools,servers,execute}`
also exist.

### Consequences for the components above

- **Component 1 (Ollama) is dropped entirely.** Without MLX it is a llama.cpp
  wrapper, and llama.cpp direct is the better wrapper.
- **Component 3 (`mlx-lm` side channel)** now comes from the same venv and is
  genuinely GPU-capable, so `mlx_lm.generate` becomes a real baseline.
- **Component 2 (llama.cpp escape hatch) is retained but demoted.** vllm-mlx's
  paged + prefix + SSD cache addresses much of the long-context weakness that
  justified it. Keep it; measure before relying on it.
- **Models** are now HuggingFace MLX repos, not Ollama tags. The Task 2 tag
  resolution becomes repo resolution.
- **Port** moves from 11434 to vllm-mlx's default.

### The declarative tradeoff, stated plainly

This leaves pure Nix. The venv is materialized imperatively by `uv` and will
not rebuild from the flake. What stays declarative is the *specification*: a
pinned requirements set committed to the repo, with the venv built from it.
Kyle chose this with the tradeoff on the table.

### Risk 1 is unchanged and still the top risk

A tool-calling probe against the 1B test model returned `tool_calls: null`;
the model emitted Python source instead. That is a capability failure of a
1B model, not a plumbing failure — but it means tool calling remains
**unproven** until tested against the real models. `--tool-call-parser
qwen3_coder` is a better starting position than Ollama's generic shim. There
is **no `muse` parser** in vllm-mlx's list, so Muse Glimmer may need `auto`
or may not parse at all. Test before relying on it.
