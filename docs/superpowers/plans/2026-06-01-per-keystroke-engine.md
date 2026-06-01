# Per-Keystroke Inline Completion Engine — Execution Plan (feat-021)

**Design:** `docs/superpowers/specs/2026-06-01-per-keystroke-engine-design.md`
**Approved:** 2026-06-01. Model: Qwen2.5-Coder-1.5B GGUF (user-chosen default, plain prefix-continuation).

Build order = §9 of the design. Each step lands with its own tests + a `feature_list.json` evidence
line. Heavy/user-gated steps (Metal build, model download, GUI/TCC smoke, signing) are flagged.

## Step 1 — Caret diagnostic (Swift) · headless-codeable, user-gated capture
- **Files:** `Owlet/Owlet/AXBridge.swift` (re-add `caretgeom` os_log: raw `CGRect` origin.y/height per
  candidate + chosen rect), `Owlet/Owlet/GhostTextOverlay.swift` (log final panel `origin.y`).
- **Do NOT** edit the flip (`AXBridge.swift:317-322`) or anchor (`GhostTextOverlay.swift:50`) — refuted
  as bug sources. Fix the AX-rect *data* path after measuring.
- **Verify (headless):** `xcodebuild test … -only-testing:OwletTests/AXBridgeGeometryTests` stays green.
- **Verify (user):** install → type in TextEdit + Notes on built-in AND external display at several
  vertical positions → `log show --predicate 'subsystem=="co.greenpassport.owlet" AND
  category=="caretgeom"' --info`. Determine constant-vs-growing; fix; remove diagnostic.

## Step 2 — Engine skeleton (Rust) · fully headless ← IN PROGRESS
- **New crate `tools/engine`** (standalone, like `tools/rewriter`; no root workspace).
- **Files:** `Cargo.toml` (deps: `serde`, `serde_json` only — defer `fst`/`symspell`/`llama-cpp-2`),
  `src/proto.rs` (message enums §6 + framing read/write), `src/main.rs` (UDS listener, accept loop,
  `Ping`→`Pong`, echo `Suggestion`).
- **Socket:** arg `--socket <path>`; `unlink()` stale path before `bind()`.
- **Verify:** `(cd tools/engine && cargo test)` — proto serde round-trip, length-prefix frame
  read/write (incl. partial reads), handshake.

## Step 3 — Host transport (Swift)

> **Corrected by advisor review (2026-06-01).** The cascade is *multi-shot per context* (one
> `ContextUpdate` → Tier 0 now + Tier 2 later), so the transport MUST be **push/streaming** — a
> drop-in `SidecarPredictor: Predicting` (one-shot `suggest() -> String`) would either drop Tier 2
> or lose the instant Tier 0, and behind the 120 ms Swift debounce delivers zero per-keystroke
> benefit while adding crash surface (a "phantom milestone"). Split into 3a (IPC unit) + 3b
> (streaming integration). **The per-tier debounce lives in the ENGINE, not Swift** (design §3/§8).

### Step 3a — IPC layer as its own tested unit (no controller changes)
- **Files:** `EngineFraming.swift` (4-byte BE length + JSON, mirrors `proto.rs`; `HostMessage`/
  `EngineMessage`/`Trigger`/`Tier`/`Range` as `Codable` with internally-tagged `type`),
  `EngineClient.swift` (UDS connect + framed read/write), `EngineSupervisor.swift` (spawn
  `Contents/Helpers/owlet-engine` via `Process`, `terminationHandler`, **unlink stale socket before
  each (re)spawn**, `Ping` health-check, `Shutdown`/terminate on quit; respawn with backoff).
- **No `AutocompleteController` changes.** Nothing existing breaks; the 145 Swift tests stay green.
- **Verify:** `xcodebuild test` — `EngineFraming` round-trip + partial-read against vectors that
  match the Rust `proto` tests; supervisor spawn/respawn/unlink logic with an injected fake process.
  Manual: spawn the real `owlet-engine`, `Ping`→`Pong`, one `ContextUpdate`→Tier 0 `Suggestion`.

### Step 3b — streaming integration (bounded brain change)
- **Files:** `SuggestionTransport.swift` (protocol: `updateContext(seq,prefix,suffix,appID,trigger,
  model,maxTokens)` fire-and-forget + a push sink `onSuggestion: @MainActor (seq, Suggestion) ->
  Void`); `SidecarTransport` (persistent `EngineClient` + background read loop → `onSuggestion`);
  `OllamaTransport` (wraps today's `OllamaPredictor`, keeps its own debounce, pushes ONE result so
  the rollback fits the same push shape); `AutocompleteController` (send `ContextUpdate` on every
  `textChanged()` with NO Swift debounce; add `receive(seq, suggestion)` gated by the existing
  `requestID`/seq; later seq/tier supersedes); `OwletApp.swift` (own the transport + supervisor);
  `Preferences.swift` + `SettingsView.swift` (engine vs Ollama-fallback toggle, model path).
- **Rollback preserved:** the Ollama `Predicting` path stays intact behind the toggle; its existing
  tests are untouched. Autocomplete stays default-off.
- **Verify:** `xcodebuild test` — controller seq-gating + supersession driven by a **fake transport
  that pushes multiple results** (Tier 0 then Tier 2); Ollama-fallback path unchanged.

## Step 4 — Tier 0 FST (Rust)
- **Files:** `tools/engine/src/tier0_fst.rs` (`fst::Map<u64>` + `Levenshtein` automaton, freq-ranked),
  wire into the accept loop on `trigger=Keystroke`, emit `tier=Complete`.
- **Verify:** `cargo test` — completion ranking, fuzzy edit-dist 1–2, round-trip; manual: instant word
  ghost in TextEdit.

## Step 5 — Tier 2 continuation + KV-cache (Rust) · heavy build, highest risk
- **Files:** `tools/engine/Cargo.toml` (+`llama-cpp-2`, `crossbeam`), `src/engine.rs` (dedicated
  `!Send` model thread, `n_past`, `clear_kv_cache_seq` **bool-checked** trim, per-step `AtomicBool`
  cancel, llama.cpp-own-tokenizer LCP, 512-token window), `--no-kv-cache` oracle flag.
- **Tokenizer:** `LlamaModel::str_to_token(&str, AddBos)` for LCP — NOT the HF `tokenizers` crate.
- **Verify:** `cargo test` — **KV-cache output byte-equals `--no-kv-cache` oracle** across
  append/edit/delete/cursor-jump; BPE-remerge LCP; `Ok(false)` trim → clear+re-prime; cancellation
  aborts mid-decode. **Adversarial review workflow** on this step (silent-failure-hunter +
  code-reviewer) given the KV silent-failure trap.

## Step 6 — Tier 1 SymSpell (Rust)
- **Files:** `tools/engine/Cargo.toml` (+`symspell`), `src/tier1_symspell.rs`, wire on
  `trigger=WordBoundary`, emit `tier=Recorrect` with `replace_range`.
- **Verify:** `cargo test` — correction candidates, supersession ordering.

## Step 7 — Packaging · user-gated (Metal build, download, signing, GUI)
- **Files:** `install.sh` (static-link engine build `-DBUILD_SHARED_LIBS=OFF`, copy →
  `Contents/Helpers/owlet-engine`, `codesign` with "Owlet Developer", download GGUF →
  `~/Library/Application Support/Owlet/models/`), `init.sh` (+`cd tools/engine && cargo test`, verify
  C/Metal toolchain), `Owlet/project.yml` (helper copy phase if needed), `README.md` (prereqs + smoke).
- **Entitlements:** static-link path → **no** new entitlements. (Fallback dylib path → only
  `cs.disable-library-validation` on the helper.)
- **Verify:** `./init.sh` clean-checkout pass; full manual smoke (design §10).

## Rollback
Settings `SuggestionTransport` toggle → Ollama fallback (no code revert). Whole subsystem behind the
default-off Autocomplete toggle. Engine is additive (new crate + additive Swift); `git revert` of the
integration commit restores today's Ollama autocomplete, zero data migration (context is ephemeral).
