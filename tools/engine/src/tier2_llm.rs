//! Tier 2 — LLM sentence continuation via `llama-cpp-2` (feat-021 Step 5).
//!
//! Feature-gated behind `tier2`, so the default build/`cargo test` never touch
//! llama.cpp. Build the real engine with `cargo build --release --features tier2`
//! (needs a C/C++ toolchain + Metal; the binding builds llama.cpp).
//!
//! ⚠️ COMPILE-PENDING. This is written against the API the hardening review verified
//! on `llama-cpp-2` 0.1.146 — `LlamaContext::clear_kv_cache_seq(Option<u32>,Option<u32>,
//! Option<u32>) -> Result<bool, _>`, `decode(&mut LlamaBatch)`, `LlamaSampler::sample/
//! accept/greedy`, `LlamaModel::str_to_token`. The batch/param/sampler *builders* vary
//! between crate versions, so the calls tagged `// API:` are the ones to adjust when you
//! first `--features tier2` build. The load-bearing CORRECTNESS (LCP recomputed every
//! call for BPE-stability, the `Ok(false)` partial-trim check, tokenizing with the
//! model's own tokenizer, per-step cancellation) is what must stay.

use std::num::NonZeroU32;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::mpsc::Receiver;

use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::context::LlamaContext;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::{AddBos, LlamaModel, Special};
use llama_cpp_2::sampling::LlamaSampler;
use llama_cpp_2::token::LlamaToken;

use crate::proto::{EngineMessage, Tier};

/// One llama sequence id; the engine serves a single editing session at a time.
const SEQ_ID: u32 = 0;
/// Sliding-window cap on prompt tokens (design §7 scale guard) — without it, decode
/// cost grows unbounded as the document grows.
const MAX_PROMPT_TOKENS: usize = 512;
/// Tier 2 generation cap (a sentence-ish continuation, not an essay).
const MAX_NEW_TOKENS: usize = 48;
/// llama context window.
const N_CTX: u32 = 2048;

/// A Tier 2 request handed to the model thread.
pub struct Job {
    pub seq: u64,
    pub prefix: String,
}

/// Run the dedicated model thread: load the model once, then process jobs until the
/// channel closes. The llama context is `!Send`, so it lives as a local here (it
/// borrows `model` on this stack) and never crosses threads. Results are delivered via
/// `emit`, which the caller wires to the shared, mutex-guarded socket writer.
///
/// `latest_seq` is the coalescing/cancellation signal: the read thread stores the most
/// recent Tier-2 seq into it; this loop skips superseded jobs and the decode loop aborts
/// between steps when its job is no longer the latest.
pub fn run_model_thread(
    model_path: String,
    no_kv_cache: bool,
    jobs: Receiver<Job>,
    latest_seq: Arc<AtomicU64>,
    emit: impl Fn(EngineMessage),
) {
    let backend = match LlamaBackend::init() {
        Ok(b) => b,
        Err(e) => return emit(EngineMessage::Error { seq: None, message: format!("backend init: {e}") }),
    };
    // API: enable Metal offload. Some versions: `with_n_gpu_layers(u32::MAX)`.
    let model_params = LlamaModelParams::default().with_n_gpu_layers(1_000);
    let model = match LlamaModel::load_from_file(&backend, &model_path, &model_params) {
        Ok(m) => m,
        Err(e) => return emit(EngineMessage::Error { seq: None, message: format!("model load: {e}") }),
    };
    // API: builder name for n_ctx varies (`with_n_ctx(Some(NonZeroU32))`).
    let ctx_params = LlamaContextParams::default().with_n_ctx(NonZeroU32::new(N_CTX));
    let mut ctx = match model.new_context(&backend, ctx_params) {
        Ok(c) => c,
        Err(e) => return emit(EngineMessage::Error { seq: None, message: format!("context: {e}") }),
    };

    let mut prev_tokens: Vec<LlamaToken> = Vec::new();

    for job in jobs {
        // Coalesce: a newer Tier-2 request already superseded this one.
        if latest_seq.load(Ordering::SeqCst) != job.seq {
            continue;
        }
        let still_current = || latest_seq.load(Ordering::SeqCst) == job.seq;
        match complete(&model, &mut ctx, &mut prev_tokens, &job.prefix, no_kv_cache, &still_current) {
            Ok(Some(text)) if !text.trim().is_empty() => emit(EngineMessage::Suggestion {
                seq: job.seq,
                tier: Tier::Sentence,
                text,
                replace_range: None,
            }),
            Ok(_) => {} // cancelled or empty — say nothing
            Err(message) => emit(EngineMessage::Error { seq: Some(job.seq), message }),
        }
    }
}

/// Continue `prefix` with the model, reusing the KV cache across calls.
///
/// `prev_tokens` mirrors exactly what is currently primed in the KV cache for `SEQ_ID`;
/// we keep it in sync so the longest-common-prefix trim is correct.
fn complete(
    model: &LlamaModel,
    ctx: &mut LlamaContext,
    prev_tokens: &mut Vec<LlamaToken>,
    prefix: &str,
    no_kv_cache: bool,
    still_current: &impl Fn() -> bool,
) -> Result<Option<String>, String> {
    // Tokenize with the MODEL's own tokenizer (NOT a separate HF `tokenizers` crate):
    // the LCP/n_past math must use the same tokenization the model decodes with, or the
    // cache silently desyncs (hardening correction). API: str_to_token signature.
    let mut new_tokens = model
        .str_to_token(prefix, AddBos::Always)
        .map_err(|e| format!("tokenize: {e}"))?;

    // Sliding window: keep BOS + the most recent tokens so decode stays bounded (§7).
    if new_tokens.len() > MAX_PROMPT_TOKENS {
        let tail_start = new_tokens.len() - MAX_PROMPT_TOKENS;
        let mut windowed = Vec::with_capacity(MAX_PROMPT_TOKENS + 1);
        windowed.push(new_tokens[0]); // BOS
        windowed.extend_from_slice(&new_tokens[tail_start..]);
        new_tokens = windowed;
    }

    // Longest common prefix in TOKEN space, recomputed EVERY call: appending a char can
    // re-merge the last BPE token, so the old token list is NOT guaranteed to be a prefix
    // of the new one (the spec's #1 correctness trap). Oracle mode forces a full re-encode.
    let mut lcp = if no_kv_cache { 0 } else { longest_common_prefix(prev_tokens, &new_tokens) };

    // Trim the KV cache to the LCP boundary: remove [lcp, end) for the sequence. This is
    // a PARTIAL removal, which `clear_kv_cache_seq` can report as `Ok(false)` (a silent
    // no-op for SWA/recurrent caches) — so we MUST inspect the bool, not just `?` it
    // (hardening correction). On false (or oracle mode), clear the whole sequence (a full
    // removal always succeeds) and re-decode from scratch.
    let trimmed = ctx
        .clear_kv_cache_seq(Some(SEQ_ID), Some(lcp as u32), None)
        .map_err(|e| format!("kv trim: {e}"))?;
    if no_kv_cache || !trimmed {
        let _ = ctx.clear_kv_cache_seq(Some(SEQ_ID), None, None); // full clear, always succeeds
        lcp = 0;
    }

    // Decode only the differing tail [lcp, len). Logits only on the final token.
    let tail = &new_tokens[lcp..];
    let mut last_logit_idx: i32 = -1;
    if !tail.is_empty() {
        let mut batch = LlamaBatch::new(tail.len(), 1); // API: (n_tokens, n_seq_max)
        for (i, &token) in tail.iter().enumerate() {
            let pos = (lcp + i) as i32;
            let is_last = i == tail.len() - 1;
            batch
                .add(token, pos, &[SEQ_ID as i32], is_last) // API: add(token,pos,seq_ids,logits)
                .map_err(|e| format!("batch add: {e}"))?;
            if is_last {
                last_logit_idx = i as i32;
            }
        }
        ctx.decode(&mut batch).map_err(|e| format!("decode prompt: {e}"))?;
    } else if let Some(&_last) = prev_tokens.get(new_tokens.len().wrapping_sub(1)) {
        // Whole prompt already cached (pure re-show): we still need logits for the last
        // position. Re-decode just the last token at its position to get fresh logits.
        let pos = (new_tokens.len() - 1) as i32;
        let mut batch = LlamaBatch::new(1, 1);
        let _ = ctx.clear_kv_cache_seq(Some(SEQ_ID), Some(pos as u32), None);
        batch
            .add(*new_tokens.last().unwrap(), pos, &[SEQ_ID as i32], true)
            .map_err(|e| format!("batch add: {e}"))?;
        ctx.decode(&mut batch).map_err(|e| format!("decode tail: {e}"))?;
        last_logit_idx = 0;
    }
    *prev_tokens = new_tokens;
    let mut n_past = prev_tokens.len() as i32;

    // Greedy decode with per-step cancellation + stop conditions (§5.3).
    let mut sampler = LlamaSampler::greedy(); // API: greedy() / chain construction
    let mut out = String::new();
    for _ in 0..MAX_NEW_TOKENS {
        if !still_current() {
            return Ok(None); // a newer keystroke superseded this request
        }
        // API: sample(ctx, idx) — idx is the batch row holding the logits we want.
        let token = sampler.sample(ctx, last_logit_idx);
        sampler.accept(token);
        if model.is_eog_token(token) {
            break;
        }
        // API: token_to_str(token, Special) — Plaintext/Tokenize variant name varies.
        let piece = model.token_to_str(token, Special::Tokenize).unwrap_or_default();
        out.push_str(&piece);
        if let Some(nl) = out.find('\n') {
            out.truncate(nl); // stop at the first line break
            break;
        }

        // Feed the generated token back to extend the cache.
        let mut batch = LlamaBatch::new(1, 1);
        batch
            .add(token, n_past, &[SEQ_ID as i32], true)
            .map_err(|e| format!("batch add gen: {e}"))?;
        ctx.decode(&mut batch).map_err(|e| format!("decode gen: {e}"))?;
        prev_tokens.push(token);
        n_past += 1;
        last_logit_idx = 0;

        if ends_sentence(&out) {
            break; // sentence terminator reached
        }
    }

    Ok(Some(out.trim_end().to_string()))
}

/// Number of leading tokens `a` and `b` share.
fn longest_common_prefix(a: &[LlamaToken], b: &[LlamaToken]) -> usize {
    a.iter().zip(b.iter()).take_while(|(x, y)| x == y).count()
}

/// True when `s` ends a sentence (so we can stop after a complete thought).
fn ends_sentence(s: &str) -> bool {
    matches!(s.trim_end().chars().last(), Some('.') | Some('!') | Some('?'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lcp_counts_shared_leading_tokens() {
        let a = [1, 2, 3, 9].map(LlamaToken);
        let b = [1, 2, 4].map(LlamaToken);
        assert_eq!(longest_common_prefix(&a, &b), 2);
        assert_eq!(longest_common_prefix(&a, &a), 4);
        assert_eq!(longest_common_prefix(&a, &[]), 0);
    }

    #[test]
    fn sentence_terminators() {
        assert!(ends_sentence("Hello world."));
        assert!(ends_sentence("Really?  "));
        assert!(!ends_sentence("not yet"));
        assert!(!ends_sentence(""));
    }

    // The KV-cache-vs-oracle equality test (design §10) needs a real GGUF and the
    // `tier2` feature, so it can't run in the default suite. With a model present, run:
    //   OWLET_TEST_MODEL=/path/model.gguf cargo test --features tier2 -- --ignored
    // and assert complete(...,no_kv_cache=false) == complete(...,no_kv_cache=true) across
    // append / edit / delete / cursor-jump prefixes (proving no BPE drift).
}
