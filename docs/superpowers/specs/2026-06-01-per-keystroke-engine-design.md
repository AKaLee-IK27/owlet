# Owlet Per-Keystroke Inline Completion Engine (Design)

**Date:** 2026-06-01
**Status:** Approved; implementation started (feat-021).
**Feature ID:** feat-021 (per-keystroke inline-completion engine — Rust `llama-cpp-2` sidecar)
**Supersedes (for autocomplete inference):** the Ollama-HTTP path from `2026-06-01-owlet-autocomplete-design.md`. The rewriter keeps Ollama.

> **Provenance.** Derived from `~/Downloads/macos-writing-suggestions-spec.md` (the external build
> spec) + a six-claim adversarial hardening pass (workflow `wf_70480b50-628`, 12 agents). Every
> "Hardening correction" below cites a verified finding; the original spec text it overrides is noted.

## 1. Goal

True **per-keystroke inline completion**: as the user types in any AX-native text field, ghost
text appears/updates with low enough latency to feel instant. Achieved via a three-tier cascade —
an instant local tier on every keystroke + a debounced, aggressively-cancelled LLM — not by running
the LLM on literally every keystroke. On-device only, never in password fields, default-off.

## 2. Why a Rust sidecar (locked decision)

The current autocomplete fires the LLM only on a pause and runs over Ollama HTTP (p50≈148 ms warm,
within budget). Moving to *true per-keystroke* — the LLM regenerating as you type, including on
edits/cursor-jumps — needs **manual KV-cache control** (trim to a token-space boundary on edits) and
**per-decode-step cancellation**, which Ollama's auto-prefix-cache does not expose. That is the one
product change that flips the verdict from "keep Ollama" to "build the engine."

- **Engine = Rust `llama-cpp-2`** (GGUF/Metal), in a **separate sidecar process** (`owlet-engine`),
  bundled at `Owlet.app/Contents/Helpers/owlet-engine`.
- **Topology = sidecar over a Unix domain socket.** Crash isolation (the model is the most
  crash-prone component), memory isolation (multi-GB weights out of the menu-bar app), and TCC
  isolation: **only the Swift `Host` calls Accessibility, so the engine needs no TCC grant.**
- The Swift `Host` keeps all macOS integration: AX reads, caret geometry, the ghost overlay,
  Tab/Right/Esc acceptance, the secure-field guard, permissions.

```
┌─────────────────────────────┐     UDS (length-prefixed JSON)     ┌──────────────────────────────┐
│  Host (Swift, menu-bar)     │◀──────────────────────────────────▶│  owlet-engine (Rust sidecar) │
│  • AX caret context + rect  │  ─ ContextUpdate(seq,prefix,…) ─▶  │  • Context buffer (ephemeral)│
│  • Ghost overlay (NSPanel)  │  ─ Cancel(seq) / Shutdown / Ping ─▶ │  • Tier0 fst  • Tier1 symspell│
│  • Tab/Right/Esc accept     │◀─ Suggestion(seq,tier,text,range) ─ │  • Tier2 llama-cpp-2 (GGUF)  │
│  • Secure-field guard, TCC  │◀─ Pong / Error ───────────────────  │  • KV-cache trim + cancel    │
└─────────────────────────────┘                                    └──────────────────────────────┘
   (has Accessibility/Input Monitoring)                              (no TCC; stdin→compute→socket)
```

## 3. Cascade (what makes it feel per-keystroke)

| Tier | Trigger | Mechanism | Budget |
|------|---------|-----------|--------|
| **0 Complete** | every keystroke | `fst` map + Levenshtein automaton (edit-dist 1–2) | sub-ms, off the model thread |
| **1 Recorrect** | word boundary / ~80–120 ms | `symspell` (edit-dist ≤2), optional LLM re-rank | spelling sub-50 ms |
| **2 Suggest** | pause ~250–400 ms / hotkey | `llama-cpp-2` greedy/low-temp, prefix-only continuation | within the pause window |

Tier 0 delivers the per-keystroke *feel*; Tier 2 is always debounced + cancelled. A later tier's
suggestion supersedes the displayed one; every `Suggestion` carries the `seq` it was computed for so
the Host drops stale results.

## 4. Model decision (user-overruled — recorded with trade-off)

**Decision (user, 2026-06-01):** v1 default = **Qwen2.5-Coder-1.5B GGUF Q4_K_M**, run in **plain
prefix-continuation mode** (FIM tokens NOT wired — suffix is captured in the protocol but ignored).

> **Recorded trade-off (hardening claim `fim-prose-model`, conf 0.93, overruled by the user).** The
> pipeline is prefix-only, so a code model's FIM machinery is structurally inert here; a code model
> can bias short prose spans toward code-like output; and it is a second download distinct from the
> rewriter's general `qwen2.5:1.5b`. The evidence recommended a **general base model** (Qwen2.5-1.5B
> base or Llama-3.2-1B base). The model is a one-line swap in the Settings picker, so this is cheap
> to revisit; the base model ships as a selectable alternate, not the default.

## 5. Hardening corrections (verified — these override the external spec)

1. **KV-cache API (claim `llama-cpp-2-kv`, 0.92).** The spec's `kv_cache_seq_rm` **does not exist**
   in `llama-cpp-2` 0.1.146. Real method: `LlamaContext::clear_kv_cache_seq(src: Option<u32>,
   p0: Option<u32>, p1: Option<u32>) -> Result<bool, KvCacheConversionError>` — **safe Rust, no
   caller-side `unsafe`** (overrides the spec's "be ready to wrap unsafe"). Trim seq `s` to a
   boundary: `clear_kv_cache_seq(Some(s), Some(boundary), None)`.
   **Silent-failure trap:** that is a *partial* removal; it can return `Ok(false)` = the cache was
   **not** trimmed (a no-op for SWA/recurrent configs). The caller **must inspect the bool** — `?`
   only catches the i32-overflow `Err`, not the `Ok(false)` no-op. On `false`: clear the whole
   sequence and re-prime, or surface an error. Never treat `?` as proof the trim happened.
   Decode/sample are synchronous and caller-driven: `decode(&mut LlamaBatch)`,
   `LlamaSampler::sample(ctx, idx)` / `accept(token)` / `greedy()` / `dist(seed)`. **Cancellation =
   the caller checks its own `AtomicBool` between decode steps** (no built-in callback).

2. **Tokenizer alignment (claim `tokenizer-alignment`, 0.83).** Do **not** use the HuggingFace
   `tokenizers` crate to compute the token-space LCP that drives `n_past`/cache trimming (the
   external spec's §6.2 reference code does exactly this — it is the antipattern). HF-vs-llama.cpp
   divergence (BOS-by-default, old/broken GGUF conversions) causes **silent, intermittent KV
   desync**. Tokenize via **llama-cpp-2's own `LlamaModel::str_to_token(&str, AddBos)`** — the same
   tokenizer that feeds `decode` — for both previous and current prompts, with one fixed BOS policy.
   Confine `tokenizers` to display/length only, or drop it. Debug assert: decoded-prefix token count
   == `n_past` after each edit.

3. **Entitlements / signing (claim `entitlements-metal-helper`, 0.86).** Owlet signs with a
   **self-signed cert ("Owlet Developer") with no Apple Team ID** (`install.sh`), so the "re-sign
   dylibs with the same Team ID" library-validation escape hatch **does not apply**.
   - **Chosen path: static-link ggml/llama (`-DBUILD_SHARED_LIBS=OFF`)** → **zero** hardened-runtime
     exception entitlements. Sign the single `owlet-engine` Mach-O; `Metal.framework`/`Foundation`
     are Apple platform binaries and always pass library validation.
   - Do **not** add `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` — Metal
     compiles shaders **out-of-process** (MTLCompilerService.xpc) and ggml CPU kernels are AOT SIMD;
     no in-process JIT. (The LM Studio `allow-jit` precedent is its Electron/V8 layer, not llama.cpp.)
   - Fallback only if shipping ggml/llama as separate dylibs: add `cs.disable-library-validation`
     **on the helper binary** (not the parent — hardened-runtime is per-Mach-O).
   - Helper needs **no TCC** (touches no protected resource; stdin→compute→socket) and **no
     `network.client`**. A `Process`/`posix_spawn` child inherits the parent as responsible process
     by default, so it triggers no TCC prompt. Accessibility/Input Monitoring stay on the parent.
   - Distribution caveat: self-signed/ad-hoc **cannot be notarized**; shipping to *other* Macs needs
     Developer ID + notarization. Local build/run is unaffected (no quarantine xattr on local builds).

4. **UDS spawn/supervise (claim `uds-spawn-macos`, 0.86).**
   - **Keep** the socket at `~/Library/Application Support/Owlet/engine.sock` (measured 59 bytes,
     well under the macOS `sun_path` 104-byte limit; dir `0700`, user-writable). Do **not** move to
     `/var/run` (root:daemon — not writable by a user agent; would fail outright). macOS has **no**
     abstract socket namespace (Linux-only), so a filesystem path is mandatory. Runtime assert:
     `path.utf8.count < 104`, fail loud.
   - Supervise with **`Process` + `terminationHandler`** (reaps the child; no hand-rolled
     waitpid/SIGCHLD). Crash detection = terminationHandler + local-socket EOF; `Ping` only for hangs.
   - **Stale-socket fix (gap in the original plan):** after a hard crash (`kill -9`/panic) the
     `engine.sock` file survives → the next `bind()` fails `EADDRINUSE` → **automatic crash recovery
     is silently dead.** The **supervisor must `unlink()` `engine.sock` immediately before each
     (re)spawn** (it serializes launches and knows via terminationHandler the prior helper is dead,
     so this is race-free). Optional future: inherited `socketpair()` fd eliminates both the path
     limit and the stale-socket problem — noted, not adopted now.

5. **Caret geometry = diagnose, not blind-fix (claim `caret-one-line-high`, plan-ok 0.88).** All
   three formula-bug hypotheses were **refuted against the actual code + git history**: the
   Quartz→Cocoa flip preserves `midY` (`AXBridge.swift:317-322`), the overlay centers on `midY`
   (`GhostTextOverlay.swift:50`), and the chip backdrop (commit e733306) was added **without touching
   the anchor**. So **no constant-one-line bug exists in the source formulas** — the residual offset
   is most likely in the **AX rect data itself** (degenerate/zero-length `kAXBoundsForRange`). Action:
   re-add a `caretgeom` os_log (raw CGRect per candidate + final panel origin), sample **multiple
   vertical positions on BOTH displays** (built-in is untested; constant-vs-growing undetermined),
   then fix the data path. **Do not ship a blind nudge to the flip or anchor.**

## 6. IPC protocol (UDS)

Transport: Unix domain socket, **length-prefixed frames** (4-byte big-endian length + UTF-8 JSON
payload). JSON (not a binary codec) is a **deliberate deviation from the external spec §7.1** — it
avoids a codegen dependency on both Swift and Rust; per-frame parse is tens of µs vs ms-scale decode.
A binary codec (postcard/bincode) is a later optimization.

- **Host → Engine:** `ContextUpdate{ seq:u64, prefix:String, suffix:String, app_id:String,
  trigger:Trigger }` where `trigger ∈ {Keystroke, WordBoundary, Pause, Hotkey}`;
  `Cancel{ seq:u64 }`; `Shutdown{}`; `Ping{}`.
- **Engine → Host:** `Suggestion{ seq:u64, tier:Tier, text:String, replace_range:Option<Range> }`
  where `tier ∈ {Complete, Recorrect, Sentence}`; `Pong{}`; `Error{ seq:Option<u64>, message:String }`.
- **Handshake:** Host connects, sends `Ping` + protocol version; Engine replies `Pong` once the model
  is loaded. Host shows "warming up" until then. Engine always works the latest `seq`; superseded
  results are dropped both sides.

## 7. Context buffer

Rolling current-sentence prefix (+ suffix, captured but ignored in v1). Cap the prefix at a **512-token
sliding window** (load-bearing scale guard: without it incremental decode grows unbounded as the
document grows). Ephemeral — never written to disk. Append (typing forward) is the fast path: feed
only the new token(s). Edit/delete/cursor-jump: recompute token-space LCP (using llama.cpp's own
tokenizer, §5.2), trim to the boundary (checking the bool, §5.1), decode only the differing tail.

> **BPE instability (external spec's #1 trap, retained):** appending a char can re-merge the last
> token, so the old token list is NOT guaranteed to be a prefix of the new one. **Recompute the LCP
> in token space every update.** "Append-only" does not exempt this.

## 8. Threading & cancellation (engine)

The llama.cpp context is `!Send` → pin it to **one dedicated OS thread**; other components talk to it
over a channel (`crossbeam`). Tier 0 and Tier 1 (spelling) run **off** the model thread. A newer
`ContextUpdate`/`Cancel` for the active session sets the cancel `AtomicBool`; the decode loop checks
it between steps and bails. Coalesce the queue — never process a backlog of stale contexts.

## 9. Build order (one MVP, ordered for buildability — not shipped as separate phases)

Each step is independently verifiable; the user asked for the full MVP, not staged releases.

1. **Caret diagnostic** (Swift) — re-add `caretgeom` os_log, capture on both displays, fix the data
   path. Independently testable; unblocks all visual smoke. (§5.5)
2. **Engine skeleton** (Rust) — crate scaffold + proto types + UDS listener + handshake (`Ping`/`Pong`)
   + trivial echo `Suggestion`. **No `llama-cpp-2` yet** (fast, `cargo test`-green). ← *started*
3. **Host transport** (Swift) — **push/streaming, not one-shot** (advisor-corrected: the cascade is
   multi-shot per `ContextUpdate`, so a drop-in `SidecarPredictor: Predicting` is wrong — it would
   drop Tier 2 or lose the instant Tier 0). Split: **3a** = IPC unit (framing + `EngineClient` +
   spawn/health-check/respawn/shutdown with **unlink-before-respawn** §5.4; no controller changes,
   tests stay green). **3b** = streaming integration (`SuggestionTransport` push protocol;
   `textChanged()` sends `ContextUpdate` immediately with **no Swift debounce — the per-tier debounce
   lives in the engine**, §3/§8; controller gains `receive(seq, suggestion)` on the existing
   `requestID`/seq gate). Keep the Ollama `Predicting` path behind a Settings toggle as rollback.
4. **Tier 0 FST** end-to-end — `fst` completion, displayed via the existing ghost overlay.
5. **Tier 2 FIM/continuation + KV-cache** — add `llama-cpp-2`, dedicated thread, LCP-trim-on-edit
   (bool-checked), per-step cancel, **+ the naive full-re-encode oracle** (`--no-kv-cache`) and a
   byte-equality test. This is the highest-risk step (the silent-failure trap lives here).
6. **Tier 1 SymSpell** recorrect, slotted in with correct supersession.
7. **Packaging** — static-link build, `Contents/Helpers/owlet-engine`, sign, GGUF download in
   `install.sh`, `init.sh` engine test, README prereqs + smoke steps.

## 10. Verification

- `(cd tools/engine && cargo test)` — proto round-trip, framing, cascade, **KV-cache == oracle**,
  BPE-remerge, cancellation, `Ok(false)` trim handling.
- `(cd tools/rewriter && cargo test)` — regression (untouched).
- `(cd Owlet && xcodebuild test …)` — transport, controller seq/cancel, AX geometry.
- `./init.sh` — clean-checkout pass (will gain the engine build + test).
- **Manual (user-only, GUI+TCC):** ghost completes as you type in TextEdit, Tab/Right/Esc behave,
  password field silent, latency feels instant; `kill owlet-engine` mid-type → Host respawns (proves
  the unlink-before-respawn fix), no crash.

## 11. Risks

| # | Risk | Mitigation |
|---|------|-----------|
| R1 | `llama-cpp-2`/llama.cpp Metal static build is heavy / breaks `init.sh` | Build engine in its own step; verify C/Metal toolchain in `init.sh`; cache target dir |
| R2 | KV-cache `Ok(false)` silent no-op → stale context | Inspect bool, fall back to full clear+re-prime; oracle equality test (§5.1, §9.5) |
| R3 | Tokenizer drift → silent KV desync | Use llama.cpp's own tokenizer for LCP; debug assert n_past (§5.2) |
| R4 | Caret offset persists after diagnosis | Diagnose-first on both displays before any fix; FST tier still works regardless (§5.5) |
| R5 | Code model produces awkward prose (user-overruled pick) | Base model selectable in picker; one-line swap (§4) |
| R6 | Engine crash takes down UX | Crash isolation + respawn + unlink-before-bind; "no suggestion" degrades cleanly |
| R7 | Distribution to other Macs blocked (no notarization) | Local build/run unaffected; notarization deferred to a release task |

## 12. Out of scope (v1)

IMKit inline ghost text (keep the floating `NSPanel`), speculative decoding, FIM token wiring,
personalization/adaptive Tier-0 weights, the optional suggestion LRU, emoji-on-colon. The rewriter is
untouched (stays on Ollama + `qwen2.5:1.5b`).
