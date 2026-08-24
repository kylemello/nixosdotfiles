# Local LLM on ariane

Metal-enabled MLX from PyPI, served by `vllm-mlx`, driven by OpenCode. Design
rationale, the failed nixpkgs attempt, and rejected alternatives are in
`docs/superpowers/specs/2026-08-24-local-llm-mlx-design.md`.

Everything below was measured on ariane (M4 Pro, 48 GB) on 2026-08-24. Where a
figure was *predicted* beforehand, the prediction is shown next to it — the
whole reason this file exists is that several predictions were wrong.

## Why a uv venv and not nixpkgs

nixpkgs builds `python3Packages.mlx` with `-DMLX_BUILD_METAL:BOOL=FALSE` and
`ollama` with `OLLAMA_MLX_BACKENDS=""`, because Nix's sandbox cannot reach
Apple's closed-source `metal` compiler. Both import and run — on the CPU,
silently reporting `Device(cpu, 0)`. Apple's PyPI wheels carry the Metal
backend in a separate `mlx-metal` package.

`llama-cpp` is the exception: it JIT-compiles its Metal shaders at *runtime*,
so it sidesteps the sandbox and nixpkgs ships it with `GGML_METAL:BOOL=TRUE`.
Verified — `libggml-metal.so` links `Metal.framework` and `MetalKit`.

The venv lives at `~/.local/share/mlx-venv` and is reproduced from
`home/llm-requirements.txt` by `llm sync`. `llm doctor` reports GPU health.

## The three models

| Slot | Repo | Params | Parser | `--mllm` |
|---|---|---|---|---|
| `llm coder` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | MoE, 8 of 128 experts | `qwen3_coder` | no |
| `llm agent` | `mlx-community/Qwen3.6-35B-A3B-4bit` | MoE, ~3B active of 35B | `qwen` | **yes** |
| `llm hard` | `mlx-community/Qwen3.8-27B-4bit` | dense 27B | `qwen` | no |

Only one loads at a time: 16–19 GiB of weights each against a 37.4 GiB GPU
working set. `llm <slot>` evicts whatever is running first.

## Measured: generation speed

| Model | Measured | Predicted | Verdict |
|---|---|---|---|
| Qwen3-Coder-30B-A3B | **88.0 tok/s** (`mlx_lm.generate`) | ~130 tok/s, third-party blog | prediction was **32% optimistic** |
| Qwen3.6-35B-A3B | **59.4 tok/s** (via server) | none — model chosen mid-project | — |
| Qwen3.8-27B | **14.7 tok/s** (via server) | ~15–20, from bandwidth arithmetic | **accurate** |
| *(Muse Glimmer 30B, dropped)* | *15.4 tok/s* | *25–35, from the spec* | *prediction was **2× optimistic*** |

Two of the four predictions were wrong, both optimistic, which is why nothing
in this file is quoted from a vendor or a blog.

The Muse Glimmer miss has a specific cause worth remembering: the 25–35 figure
assumed its DFlash speculative decoder, which was never enabled. A prediction
for a configuration you do not actually run is not a prediction.

Coder and agent numbers are not perfectly comparable — the coder was measured
with `mlx_lm.generate` directly, the other two through the HTTP server, which
adds tool-parsing and transport overhead.

### Why the dense model is slow, and why that is not fixable

Generation is **memory-bandwidth bound**, not compute bound: every token reads
all *active* weights out of RAM once. The M4 Pro has 273 GB/s.

- Qwen3.8-27B is dense: ~14 GiB read per token → ceiling ~19.5 tok/s. Measured
  14.7, i.e. ~75% of the bus limit.
- Qwen3-Coder is MoE: only ~3.3B of 30.5B params move per token, so it reads
  roughly 7× less and runs roughly 6× faster despite being larger on disk.

No MLX setting changes this. MLX gets you close to the bus limit; it cannot
widen the bus. Choosing MoE over dense is the only real lever.

## Tool calling

**All three models tool-call correctly.** This was the project's top risk and
it is closed. Each returned `finish_reason: "tool_calls"` with the right
function and correctly-extracted arguments. Additionally verified on the coder:

- multi-turn — consumed a `role: tool` result and answered from it
- tool selection — picked `read_file` over `get_weather` from a two-tool menu

## `--continuous-batching` is load-bearing, and its help text is wrong

Its `--help` reads *"for multiple concurrent users (slower for single user)"*.
For a single user running agent loops it is the difference between a working
prefix cache and none at all. Measured on an 8K repeated prefix:

```
without --continuous-batching:  11.34s / 10.97s / 10.98s   (no caching)
with    --continuous-batching:  13.56s / 11.90s /  0.42s   (28x on hit)
```

Only in batched mode does the server construct the cache
(`MemoryAwarePrefixCache initialized: max_memory=2703.2MB`). In simple mode
`/v1/cache/stats` reports all zeros and **every request re-prefills** — which
in an agent loop means re-reading the whole transcript on every tool call.

Ruled out before concluding this: `--use-paged-cache` was not the cause,
`--enable-prefix-cache` is already default-on, `--prefix-cache-size` is
documented "legacy mode only", and there is no warming endpoint
(`/v1/cache/prefix` accepts DELETE only).

## Measured: long context (~40K tokens)

Same prompt three times, coder model, `--continuous-batching` on:

```
run 1  118.2s   cold -- full 40K prefill at ~338 tok/s
run 2  117.0s   still cold
run 3    1.58s  cache hit -- 75x faster, 35,891 tokens saved
```

**Run 2 does not hit.** The cache commits its entry after a completion, so the
first repeat still pays full price; the third request is the first to benefit.
This is harmless for agent loops, where a tool executes between turns, but it
means a naive A/B benchmark of two runs will conclude the cache does nothing.
That is exactly the mistake this project made once already.

Practical read: a cold 40K context costs ~2 minutes. After that, every turn
that shares the prefix is effectively free. The prefix cache holds ~3.1 GB and
40K tokens consumed ~1.9 GB of it, so expect room for one or two large
contexts before eviction.

## Which model when

Written from the numbers above, not from vendor claims.

- **`llm coder`** — bulk work, completions, anything throughput-bound. Fastest
  by a wide margin at 88 tok/s.
- **`llm agent`** — multi-step tool use. 59 tok/s and a first-class `qwen`
  parser; the natural default for OpenCode sessions.
- **`llm hard`** — problems worth waiting on. 15 tok/s is roughly 6x slower
  than the coder, so reach for it deliberately, not by default.
- **`llm long`** — **rarely, if ever.** The original design assumed MLX would
  collapse past 60K and llama.cpp would rescue it. With `--continuous-batching`
  the prefix cache makes repeated long contexts cost 1.58s, so the hatch is
  mostly redundant. It also cannot read these models (MLX safetensors, not
  GGUF) and llama.cpp has open `qwen3_5` correctness bugs. Treat it as a
  contingency, not a workflow.

## `HF_HUB_OFFLINE=1`, not `--offline`

vllm-mlx's own `--offline` flag **fails to resolve models that are present in
the HF cache**:

```
RuntimeError: Model 'mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit'
not found in local cache. Download it first without --offline flag.
```

…for a model that serves fine without the flag. `HF_HUB_OFFLINE=1` is
huggingface_hub's canonical switch, is honoured correctly, and is what
`home/llm.nix` exports.

## PHI posture

- Server binds `127.0.0.1` only. Verified: no off-loopback listeners.
- Bearer auth enforced — no key → 401, wrong key → 401, correct key → 200.
- Key at `~/.config/mlx/api-key`, mode 0600, never committed. The Nix store
  holds only the literal placeholder `{file:~/.config/mlx/api-key}`, which
  OpenCode resolves at runtime — store paths are world-readable and this repo
  is public.
- `HF_HUB_OFFLINE=1` during serving: no weight fetches during inference.
- OpenCode config declares **exactly one provider**. With no cloud provider
  configured there is nothing to fall back to. `share: "disabled"` stops
  transcript upload, which is the real egress path (there is no separate
  telemetry SDK in OpenCode).

**One caveat, stated plainly:** OpenCode's provider is declared as
`npm = "@ai-sdk/openai-compatible"`, and on *first* use it fetches that package
from npm. That is a one-time setup cost, not per-inference traffic, but it is
network activity — do the first run before you start handling anything
sensitive. It is also why the first `opencode run` appears to hang for minutes;
subsequent runs complete in seconds.

## Usage

```
llm coder     # fast bulk work, completions      ~88 tok/s
llm agent     # tool use, agentic loops          ~59 tok/s
llm hard      # best quality, thinking mode      ~15 tok/s
llm long f.gguf   # llama.cpp, prompts >60K
llm status    # what is loaded + prefix-cache hit stats
llm stop      # tear down, free the memory
llm doctor    # venv health, GPU check
```

Then point OpenCode at it:

```
opencode run --model mlx/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit "..."
```

Model ids contain slashes; that is fine. OpenCode splits on the **first** slash
only and passes the rest through verbatim.

Verified end-to-end: OpenCode read a file, diagnosed a seeded bug, edited it,
and exited cleanly in ~4 s.

## GPU memory limit

`mx.device_info()` reports a **37.4 GiB** max recommended working set against
48 GB physical — macOS caps GPU-addressable unified memory at ~75% by default.
Raise it for a session with:

```
sudo sysctl iogpu.wired_limit_mb=40960
```

Needs `sudo`, does not survive reboot, which is why it is documented here
rather than managed by Home Manager. `--kv-cache-quantization-bits 4` (already
in the serve flags) is the other lever and needs no root.

## The llama.cpp escape hatch

`llama-server` build 10408 is installed, with working Metal. Two caveats:

1. **No GGUF is downloaded by this setup.** The three models above are MLX
   safetensors, which llama.cpp cannot read. Fetch a GGUF yourself.
2. llama.cpp's support for the `qwen3_5` hybrid architecture used by
   Qwen3.6-35B-A3B and Qwen3.8-27B had **open conversion/inference correctness
   bugs** as of 2026-08-22. Verify output sanity before trusting this path for
   those two families.

Given vllm-mlx's prefix cache works once `--continuous-batching` is on, this
hatch is far less necessary than the original design assumed. Measure before
reaching for it.
