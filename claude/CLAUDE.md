# User preferences (all projects, all machines)

<!-- Disabled 2026-09-22 to test Opus 5.5 default output; delete the comment markers to restore.
## Response style

**Default shape: lead with the outcome in one or two plain sentences. Then
bullets, only for details that change what I do next. Then stop.**

```
Fixed. The fish prompt was calling `date` twice per render.

- Cached the timestamp in `__prompt_ts` (fish.nix:42)
- Reset it in the preexec hook (fish.nix:58)

`nix eval` builds clean.
```

### Cut
- Preamble. No restating my request, no "Great question", no announcing intent.
- Recap. Don't summarize what you just did if the diff or tool calls already show it.
- Tool narration. "Let me read...", "Now I'll check...", "I'll start by..." — just do it.
- Hedges and filler: *just, really, basically, essentially, actually, simply,
  it's worth noting, in order to, that being said*.
- Closing offers: "Let me know if...", "Happy to...", "Feel free to...".
- Options I'm not going to pursue. Recommend one; don't survey the field.
- **The test:** if a sentence would fit unchanged in a *different* conversation, delete it.

### Clarity (the point is digestible, not merely short)
- Plain language first. If jargon is unavoidable, define it inline the first time in ≤6 words.
- Name the concrete thing, not the abstraction. "The prompt called `date` twice"
  beats "there was a redundant subprocess invocation in the render path".
- Point at real referents: `file:line`, the actual command, the actual value.
  Never "the config", "the relevant module", "the appropriate handler".
- One level of explanation. Don't explain the explanation.
- If something genuinely is complex, say so in one sentence and give the simplest
  correct mental model — not the full mechanism.
- Prose over structure. Headers only when there are 3+ genuinely distinct sections.
  No nested bullets. One idea per bullet, ~15 words; fragments are fine.

### Length budget
| Ask | Response |
|-----|----------|
| Factual / yes-no | 1–3 sentences, no bullets |
| Normal task | 1 outcome sentence + ≤5 bullets |
| Large / multi-part | Short headers, ~15 lines of prose max |

Exceed this only when I explicitly ask for depth — "explain", "walk me through", "why".

### Never cut
Brevity is about ceremony, never about truth. Always keep, at full length if needed:
- Security concerns, data-loss risk, and confirmations before destructive or
  outward-facing actions.
- Anything you **failed** to do, skipped, or could not verify. Say it plainly.
- Test / build / lint failures, with the actual output.
- Assumptions you made on an ambiguous ask.

Say "I didn't verify X" rather than quietly omitting X. Vagueness is not brevity.
-->

## Code and comments
- Match the surrounding comment density and naming. No comments restating obvious
  lines, no multi-paragraph docstrings.
- Don't create README, summary, or documentation files unless I ask.

## Verifying UI / visual changes
- The user visually confirms UI/visual results themselves. Do **not** launch or
  drive a simulator/emulator/browser, or take screenshots, just to self-verify how
  a change looks. Make the change, then hand off to the user for the visual check.
- Non-visual verification is still expected: run typecheck / lint / tests / build
  as appropriate and report the results.

## Waiting and timeouts
- Don't burn wall-clock waiting. No `sleep`, no poll loops, no re-checking a
  thing that already told you it finished. Run it, read the result, move on.
- Background work wakes you when it exits. Start it and do something else
  instead of sitting on it.
- Set a command's timeout to what it actually needs, not the maximum. A hung
  command should fail fast, not stall for minutes.
- If a wait is genuinely unavoidable — a service that must be up before the
  next step, a build with no completion signal — say so *before* it, naming
  what you're waiting on and for how long: "Waiting 30s for the MLX server to
  load weights." Same for a retry: say why the first wait wasn't enough.

## Subagents: parallelize to save time

I'll spend tokens to save wall-clock time. For implementation work this
overrides the default "when in doubt, don't spawn": if a task splits into
independent pieces, run them in parallel. (Written for the main thread. A
subagent does only its own piece, and the only agent it spawns is its reviewer.)

### When
- **Fan out** when the work splits into 2+ pieces that touch disjoint files and
  don't need each other's output: the same change across several modules, a
  feature and its tests, an API and its caller once the contract is fixed.
- **Fan out reading too.** Several unknowns up front → one Explore agent each,
  all in one message.
- **Don't** for a handful of edits, a strict chain where each step needs the
  last one's result, or debugging where understanding the cause is the bottleneck.
- Up to ~20 agents in flight. Size pieces so each is worth an agent; never
  split one file's change across several.

### Models and effort
- Every agent runs on Opus: pass `model: "opus"` so no agent definition
  downgrades it.
- I authorize you to set `effort` on every agent; pick it per piece. `low` for
  mechanical or fully specified work and Explore searches, `medium` for a normal
  piece with a clear contract, `high` for real logic or tricky edge cases.
  Implementers never get `xhigh`/`max`; that's the reviewer's job.
- Implement with fresh `general-purpose` agents. Forks ignore `effort` and run
  at yours, so fork only when a piece needs context too rich to brief.

### How
1. **Plan first, in the main thread,** and write it to a file in the
   scratchpad: the contract (signatures, names, data shapes), conventions to
   match, a table of pieces with the files each one owns, and the reviewer
   brief (see Review). Every agent gets that file's absolute path, so briefs
   stay short and all agents build against the same contract.
2. **State the split in one line before launching**: "Splitting into 6: four
   modules to agents (low), the parser to an agent (high), the glue myself."
3. **One owner per file.** Each agent edits only the files the plan assigns
   it. Use `isolation: "worktree"` only when pieces truly must share files.
4. **Every brief includes**: the plan path, which piece it owns, the narrowest
   check to run (one test file, one typecheck target; none if checks can't run
   concurrently), the review step below, and the report format: files changed,
   check result, review findings, anything skipped or changed from the plan.
   A few lines, no recap.
5. **Subagents don't commit, push, run the full suite, or spawn any agent but
   their reviewer.** The main thread owns git and final verification. Say so
   in the brief: a subagent that reads a repo's "commit every change" rule
   will commit half a feature.
6. **Launch all independent agents in one message, then keep working** on the
   critical-path piece yourself (usually what the others plug into, or the
   glue). Don't sit idle waiting.

### Review
Low-effort work gets a high-effort check before it counts as done.
- **Each implementer reviews its own piece before reporting.** It spawns one
  reviewer (`model: "opus"`, `effort: "xhigh"`) with the reviewer brief from
  the plan, passing only the plan path, its piece, and its files: never its
  own account of what it did.
- **Reviewers report and nothing else**: bugs, contract violations and missed
  edge cases with `file:line` and a concrete failure case. No style nits, no
  edits, no agents of their own.
- **The implementer fixes every finding or escalates it**, never drops one.
  Its report includes the findings verbatim, each marked fixed or disputed.
  Re-review only if a fix was substantial.
- **The main thread** settles disputed findings, then runs one xhigh review
  of the whole diff focused on the seams between pieces, then the full
  typecheck / lint / test / build.
