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
| Coding / bulk | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` |
| Agentic | `mlx-community/Muse-Glimmer-30B-4bit` |

Both are 4-bit MLX quantizations from `mlx-community`, the canonical MLX
conversion org, and both carry `config.json`, `tokenizer_config.json`, and
`chat_template.jinja` — the last is what tool calling depends on.

Muse Glimmer is multimodal by design (it accepts text and images), which
shows up in `config.json` as `architectures:
["MuseGlimmerForConditionalGeneration"]` with a `vision_config` and a
`muse_glimmer_text` submodel. It is registered under `mlx_vlm`, not `mlx_lm`
— see the loader note below. Its chat template also renders OpenAI
harmony-family tokens (`<|start|>`, `<|message|>`, `<|eot|>`, `to=self` /
`to=example` recipients), which is why `vllm-mlx --tool-call-parser harmony`
is the first thing to try when serving it (Task 3), not `auto`.

## Measured on ariane (M4 Pro, 48 GB)

Short context (~50-70 token rendered prompt), no server, raw MLX:

| Model | Loader | Prompt tok/s | Generation tok/s | Peak memory |
|---|---|---|---|---|
| `Qwen3-Coder-30B-A3B-Instruct-4bit` | `mlx_lm.generate` | 12.211 | 88.048 | 17.250 GB |
| `Muse-Glimmer-30B-4bit` | `mlx_vlm.generate --verbose` | 60.054 | 15.389 | 19.646 GB |

Both runs: prompt "Write a Python function that reverses a linked list.",
`--max-tokens 200`.

**Different loaders, on purpose.** `mlx_lm.generate` cannot load Muse
Glimmer at all (`ValueError: Model type muse_glimmer not supported`) —
`mlx_lm`'s model registry has no `muse_glimmer.py`; the architecture only
exists under `mlx_vlm/models/muse_glimmer/`. This is expected given the
model is a VLM, not a load failure to work around. `mlx_vlm.generate` is
also the only one of the two that needs `--verbose` to print the tok/s
footer at all — without it, no stats are emitted.

The coder model's measured generation speed (88.048 tok/s) came in well
below the ~130 tok/s third-party figure cited for this model shape in the
design doc. That gap is exactly why this step measures on real hardware
instead of trusting a blog number — the 130 figure is not used anywhere in
this repo.

Long-context figures are added by Task 7.

## GPU memory limit

`mx.device_info()` reports a **37.4 GiB** max recommended working set against
48 GB of physical memory — macOS caps GPU-addressable unified memory at ~75%
by default. Measured peak memory for a single loaded model plus a short
generation is 17.25 GB (coder) and 19.65 GB (agentic) — each comfortably
under the 37.4 GiB ceiling on its own, but neither leaves much room to run
both at once, and either one alone still leaves only ~18-20 GB of headroom
for KV cache at longer contexts. Raise the ceiling for a session with:

    sudo sysctl iogpu.wired_limit_mb=40960

Needs `sudo` and does not survive reboot, which is why it is documented here
rather than managed by Home Manager. `vllm-mlx --kv-cache-quantization
--kv-cache-quantization-bits 4` is the other lever and does not need root.
