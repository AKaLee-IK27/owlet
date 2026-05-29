use std::io::{self, Read, Write};
use std::process::ExitCode;
use std::time::Duration;
use linkify::LinkFinder;

const OLLAMA_URL: &str = "http://localhost:11434/api/chat";
const TIMEOUT_SECS: u64 = 30;
const DEFAULT_MODEL: &str = "qwen3:8b";

struct Args {
    model: String,
    context: Option<String>,
}

fn parse_args(args: &[String]) -> Result<Args, String> {
    // Tiny hand-rolled parser — clap would be overkill for two flags.
    let mut i = 1;
    let mut model: Option<String> = None;
    let mut context: Option<String> = None;
    while i < args.len() {
        match args[i].as_str() {
            "--model" => {
                let v = args.get(i + 1).ok_or_else(|| "--model requires a value".to_string())?;
                model = Some(v.clone());
                i += 2;
            }
            "--context" => {
                let v = args.get(i + 1).ok_or_else(|| "--context requires a value".to_string())?;
                context = Some(v.clone());
                i += 2;
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(Args {
        model: model.unwrap_or_else(|| DEFAULT_MODEL.to_string()),
        context,
    })
}

const SYSTEM_PROMPT: &str = r#"You are a prompt engineering assistant. Rewrite the user's draft prompt — intended for a chat AI like Claude, GPT, or Gemini — so it produces better answers.

Apply structural prompt engineering. Do not just fix grammar or polish style — frontier models handle imperfect language fine. The improvement must be substantive.

# Language
Preserve the language of the input.
- Vietnamese input → improved Vietnamese.
- English input → improved English.
- Mixed Vietnamese prose with English technical terms → keep the mix; do not translate either way.
- Other languages → preserve.

All the structural improvements below apply in whichever language the user wrote in.

# What to improve (apply only where it serves the user's intent)
1. Specificity — replace vague words with concrete ones when the user's intent makes the right choice clear.
2. Output format — if the user implied a format (list, table, code block, JSON, steps), make it explicit.
3. Role / persona — if the task benefits from expertise, name the role the AI should adopt.
4. Constraints — if the user implied scope (length, audience, style, depth), state it explicitly.
5. Examples — if the task is ambiguous and 1-2 example patterns would clarify it, add one. Otherwise don't.

For code or technical prompts: specify language, runtime, or version when the user has implied them. Do not invent a stack the user didn't gesture at.

# What to preserve exactly
- Intent. Never add requirements the user didn't ask for.
- Tone and voice. Casual stays casual, playful stays playful, formal stays formal.
- Scope. Do not expand a small ask into a big one.

# What NOT to do
- No politeness filler ("Please", "I would like to", "Could you kindly").
- No invented constraints (no "max 200 words" if length wasn't implied).
- Do not over-specify a deliberately short prompt. "write a poem" stays open-ended — add gentle structure only if it clearly helps.
- No preamble, no explanation, no headers, no meta-commentary, no surrounding quotes or code fences.

# When the input is already a good prompt
Return it with minimal or no changes. Do not improve for the sake of improving.

# When the input is very long
Preserve the full content. Tighten only language and structure. Never summarize or truncate.

# User-provided context
The user message may begin with a [CONTEXT]…[/CONTEXT] block. Treat it as guidance about audience, scope, tone, or constraints for this rewrite. Apply it. Never repeat, quote, or mention the context block in your output — rewrite only the draft that follows it.

# Output
Only the rewritten prompt. Nothing else."#;

#[derive(Debug)]
enum RewriteError {
    Timeout,
    ConnectionRefused,
    Http(String),
    Parse(String),
    Empty,
}

impl RewriteError {
    fn stderr_message(&self) -> String {
        match self {
            RewriteError::Timeout => "ERROR: Ollama request timed out".into(),
            RewriteError::ConnectionRefused => {
                "ERROR: Connection to Ollama refused; is 'ollama serve' running?".into()
            }
            RewriteError::Http(detail) => format!("ERROR: Ollama HTTP error: {detail}"),
            RewriteError::Parse(reason) => format!("ERROR: malformed Ollama response: {reason}"),
            RewriteError::Empty => "ERROR: empty rewrite output".into(),
        }
    }
}

/// Re-append any original link whose token was DROPPED by the model (absent from
/// `model_output`, the cleaned pre-restore text). Detection is by exact token
/// presence — the same notion `restore_links` uses — so it never guesses at URL
/// string shapes. Label-free (a header would break language preservation) and
/// deduped by URL value (a URL that survived via another token instance is not
/// re-appended). Each appended link on its own line after one blank line.
fn append_dropped(restored: &str, model_output: &str, originals: &[String], prefix: &str) -> String {
    // Each token's survival, checked once and reused by both passes below.
    let token_survived: Vec<bool> = (0..originals.len())
        .map(|i| model_output.contains(&format!("{prefix}{i}Z")))
        .collect();
    // URLs that survived via at least one surviving token instance.
    let survived: Vec<&str> = originals
        .iter()
        .enumerate()
        .filter(|(i, _)| token_survived[*i])
        .map(|(_, original)| original.as_str())
        .collect();
    let mut dropped: Vec<&str> = Vec::new();
    for (i, original) in originals.iter().enumerate() {
        if token_survived[i] {
            continue; // token survived → restored inline
        }
        let url = original.as_str();
        if !survived.contains(&url) && !dropped.contains(&url) {
            dropped.push(url);
        }
    }
    if dropped.is_empty() {
        return restored.to_string();
    }
    let mut out = restored.trim_end().to_string();
    out.push_str("\n\n");
    out.push_str(&dropped.join("\n"));
    out
}

/// Replace each exact token `<prefix><index>Z` with its original span.
/// Tokens the model dropped/altered aren't found and are left for `append_dropped`.
fn restore_links(text: &str, originals: &[String], prefix: &str) -> String {
    let mut out = text.to_string();
    for (i, original) in originals.iter().enumerate() {
        let token = format!("{prefix}{i}Z");
        out = out.replace(&token, original);
    }
    out
}

/// Replace every URL/email span with an opaque token `<prefix><index>Z`.
/// Returns (masked_text, originals_by_index, prefix). No links → input unchanged, empty originals, empty prefix.
fn mask_links(input: &str) -> (String, Vec<String>, String) {
    let finder = LinkFinder::new(); // URLs (scheme required) + emails
    let links: Vec<_> = finder.links(input).collect();
    if links.is_empty() {
        return (input.to_string(), Vec::new(), String::new());
    }
    let prefix = pick_prefix(input);
    let mut originals: Vec<String> = Vec::with_capacity(links.len());
    let mut masked = String::with_capacity(input.len());
    let mut last = 0;
    for link in &links {
        masked.push_str(&input[last..link.start()]);
        let idx = originals.len();
        masked.push_str(&format!("{prefix}{idx}Z"));
        originals.push(link.as_str().to_string());
        last = link.end();
    }
    masked.push_str(&input[last..]);
    (masked, originals, prefix)
}

/// Choose a sentinel prefix that does not already occur in the input.
/// Default is `OWLETLINKZ`; only bumped for pathological inputs. Tokens are `<prefix><index>Z`.
fn pick_prefix(input: &str) -> String {
    let base = "OWLETLINKZ";
    if !input.contains(base) {
        return base.to_string();
    }
    let mut n = 2;
    loop {
        let candidate = format!("OWLETLINK{n}Z");
        if !input.contains(&candidate) {
            return candidate;
        }
        n += 1;
    }
}

fn strip_think_blocks(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(start) = rest.find("<think>") {
        out.push_str(&rest[..start]);
        let after_open = &rest[start + "<think>".len()..];
        match after_open.find("</think>") {
            Some(end_rel) => rest = &after_open[end_rel + "</think>".len()..],
            None => {
                out.push_str(&rest[start..]); // unterminated — emit as-is
                return out;
            }
        }
    }
    out.push_str(rest);
    out
}

fn strip_wrapping_quotes(input: &str) -> String {
    let trimmed = input.trim();
    let bytes = trimmed.as_bytes();
    if bytes.len() >= 2 {
        let first = bytes[0];
        let last = bytes[bytes.len() - 1];
        if (first == b'"' || first == b'\'') && first == last {
            let count = bytes.iter().filter(|&&b| b == first).count();
            if count == 2 {
                return trimmed[1..trimmed.len() - 1].trim().to_string();
            }
        }
    }
    trimmed.to_string()
}

fn clean_output(raw: &str) -> String {
    strip_wrapping_quotes(&strip_think_blocks(raw))
}

fn parse_response(body: &str) -> Result<String, RewriteError> {
    let v: serde_json::Value =
        serde_json::from_str(body).map_err(|e| RewriteError::Parse(e.to_string()))?;
    v.get("message")
        .and_then(|m| m.get("content"))
        .and_then(|c| c.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| RewriteError::Parse("missing message.content".into()))
}

fn build_payload(prompt: &str, model: &str, context: Option<&str>) -> serde_json::Value {
    let user_content = match context {
        Some(ctx) if !ctx.trim().is_empty() => {
            format!("[CONTEXT]\n{}\n[/CONTEXT]\n\n{prompt}", ctx.trim())
        }
        _ => prompt.to_string(),
    };
    serde_json::json!({
        "model": model,
        "messages": [
            { "role": "system", "content": SYSTEM_PROMPT },
            { "role": "user",   "content": user_content },
        ],
        "stream": false,
        "think": false,
        "options": { "temperature": 0.2 }
    })
}

fn call_ollama(prompt: &str, model: &str, context: Option<&str>) -> Result<String, RewriteError> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(TIMEOUT_SECS))
        .build();
    let payload = build_payload(prompt, model, context);
    match agent.post(OLLAMA_URL).send_json(payload) {
        Ok(response) => {
            let body = response
                .into_string()
                .map_err(|e| RewriteError::Parse(e.to_string()))?;
            parse_response(&body)
        }
        Err(ureq::Error::Status(code, response)) => {
            let body = response.into_string().unwrap_or_default();
            let excerpt: String = body.chars().take(200).collect();
            Err(RewriteError::Http(format!("HTTP {code}: {excerpt}")))
        }
        Err(ureq::Error::Transport(transport)) => {
            let kind = transport.kind();
            let msg = transport.message().unwrap_or("").to_lowercase();
            // Check phrasing before kind: ureq 2.12 reports timeouts as
            // ErrorKind::Io with "timed out" in the message, not as a
            // distinct variant. Phrase-first means a connect-phase timeout
            // (kind=ConnectionFailed + msg="timed out") still routes to
            // Timeout, which is what the user wants to see.
            if msg.contains("timed out") || msg.contains("timeout") {
                Err(RewriteError::Timeout)
            } else if matches!(kind, ureq::ErrorKind::ConnectionFailed)
                || msg.contains("refused")
            {
                Err(RewriteError::ConnectionRefused)
            } else {
                Err(RewriteError::Http(format!("{kind:?}: {msg}")))
            }
        }
    }
}

fn run(args: &[String]) -> Result<Option<String>, RewriteError> {
    let parsed = parse_args(args).map_err(RewriteError::Parse)?;
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|e| RewriteError::Parse(format!("stdin: {e}")))?;
    if input.trim().is_empty() {
        return Ok(None);
    }
    let (masked, originals, prefix) = mask_links(&input);
    let raw = call_ollama(&masked, &parsed.model, parsed.context.as_deref())?;
    let cleaned = clean_output(&raw);
    if cleaned.trim().is_empty() {
        return Err(RewriteError::Empty);
    }
    let restored = restore_links(&cleaned, &originals, &prefix);
    let final_text = append_dropped(&restored, &cleaned, &originals, &prefix);
    Ok(Some(final_text))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match run(&args) {
        Ok(Some(s)) => {
            let stdout = io::stdout();
            let mut handle = stdout.lock();
            if let Err(e) = handle.write_all(s.as_bytes()) {
                eprintln!("ERROR: stdout write failed: {e}");
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
        Ok(None) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("{}", err.stderr_message());
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn append_dropped_noop_when_token_present() {
        let originals = vec!["https://kept.io".to_string()];
        let out = append_dropped("text with https://kept.io inside",
                                 "text with OWLETLINKZ0Z inside", &originals, "OWLETLINKZ");
        assert_eq!(out, "text with https://kept.io inside");
    }

    #[test]
    fn append_dropped_appends_missing_label_free() {
        let originals = vec!["https://gone.com".to_string()];
        let out = append_dropped("rewritten text", "rewritten text", &originals, "OWLETLINKZ");
        assert_eq!(out, "rewritten text\n\nhttps://gone.com");
    }

    #[test]
    fn append_dropped_multiple_missing_each_on_own_line() {
        let originals = vec!["https://a.com".to_string(), "https://b.com".to_string()];
        let out = append_dropped("nothing here", "nothing here", &originals, "OWLETLINKZ");
        assert_eq!(out, "nothing here\n\nhttps://a.com\nhttps://b.com");
    }

    #[test]
    fn append_dropped_substring_url_still_appended() {
        // Short URL is a substring of a surviving long URL, and the short one was dropped.
        let originals = vec!["https://a.com".to_string(), "https://a.com/docs".to_string()];
        // Model kept token 1 (long), dropped token 0 (short).
        let out = append_dropped("only https://a.com/docs survived",
                                 "only OWLETLINKZ1Z survived", &originals, "OWLETLINKZ");
        assert_eq!(out, "only https://a.com/docs survived\n\nhttps://a.com");
    }

    #[test]
    fn append_dropped_dedupes_repeated_url_when_one_survives() {
        // Same URL twice (tokens 0,1). Model kept token 0, dropped token 1 — do NOT duplicate.
        let originals = vec!["https://dup.io".to_string(), "https://dup.io".to_string()];
        let out = append_dropped("kept https://dup.io once",
                                 "kept OWLETLINKZ0Z once", &originals, "OWLETLINKZ");
        assert_eq!(out, "kept https://dup.io once");
    }

    #[test]
    fn append_dropped_token_self_delimiting_two_digit_index() {
        // Token OWLETLINKZ1Z must not be considered present just because the output
        // contains OWLETLINKZ10Z (trailing Z makes tokens self-delimiting).
        let originals: Vec<String> = (0..=10).map(|i| format!("https://e.com/{i}")).collect();
        let out = append_dropped("see https://e.com/10", "see OWLETLINKZ10Z", &originals, "OWLETLINKZ");
        let appended: Vec<&str> = out.split("\n\n").nth(1).unwrap_or("").lines().collect();
        assert!(appended.contains(&"https://e.com/1"));    // index 1 dropped → appended
        assert!(!appended.contains(&"https://e.com/10"));  // index 10 survived → not appended
    }

    #[test]
    fn restore_links_round_trips_exact() {
        let originals = vec!["https://ex.com/a_b?x=1".to_string()];
        let restored = restore_links("see OWLETLINKZ0Z now", &originals, "OWLETLINKZ");
        assert_eq!(restored, "see https://ex.com/a_b?x=1 now");
    }
    #[test]
    fn restore_links_multiple() {
        let originals = vec!["me@x.com".to_string(), "https://y.io".to_string()];
        let restored = restore_links("mail OWLETLINKZ0Z or OWLETLINKZ1Z", &originals, "OWLETLINKZ");
        assert_eq!(restored, "mail me@x.com or https://y.io");
    }
    #[test]
    fn restore_links_missing_token_left_as_is() {
        let originals = vec!["https://gone.com".to_string(), "https://kept.io".to_string()];
        let restored = restore_links("only OWLETLINKZ1Z survived", &originals, "OWLETLINKZ");
        assert_eq!(restored, "only https://kept.io survived");
    }

    #[test]
    fn mask_links_no_links_is_noop() {
        let (masked, originals, prefix) = mask_links("just some words");
        assert_eq!(masked, "just some words");
        assert!(originals.is_empty());
        assert_eq!(prefix, "");
    }
    #[test]
    fn mask_links_replaces_url() {
        let (masked, originals, _prefix) = mask_links("see https://ex.com/a_b now");
        assert_eq!(masked, "see OWLETLINKZ0Z now");
        assert_eq!(originals, vec!["https://ex.com/a_b".to_string()]);
    }
    #[test]
    fn mask_links_replaces_email_and_url_in_order() {
        let (masked, originals, _prefix) = mask_links("mail me@x.com or visit https://y.io");
        assert_eq!(masked, "mail OWLETLINKZ0Z or visit OWLETLINKZ1Z");
        assert_eq!(originals, vec!["me@x.com".to_string(), "https://y.io".to_string()]);
    }
    #[test]
    fn mask_links_excludes_trailing_period() {
        let (masked, originals, _prefix) = mask_links("go to https://ex.com.");
        assert_eq!(masked, "go to OWLETLINKZ0Z.");
        assert_eq!(originals, vec!["https://ex.com".to_string()]);
    }

    #[test]
    fn pick_prefix_default_when_no_collision() {
        assert_eq!(pick_prefix("plain text https://ex.com"), "OWLETLINKZ");
    }
    #[test]
    fn pick_prefix_bumps_on_collision() {
        let p = pick_prefix("weird OWLETLINKZ in the text");
        assert_ne!(p, "OWLETLINKZ");
        assert!(!"weird OWLETLINKZ in the text".contains(&p));
    }

    #[test]
    fn mask_restore_round_trip_with_bumped_prefix() {
        let input = "OWLETLINKZ is in the text, see https://ex.com";
        let (masked, originals, prefix) = mask_links(input);
        assert_ne!(prefix, "OWLETLINKZ");
        let restored = restore_links(&masked, &originals, &prefix);
        assert_eq!(restored, input);
    }

    #[test]
    fn strip_think_empty() {
        assert_eq!(strip_think_blocks(""), "");
    }

    #[test]
    fn strip_think_no_block() {
        assert_eq!(strip_think_blocks("hello world"), "hello world");
    }

    #[test]
    fn strip_think_single_block() {
        assert_eq!(strip_think_blocks("hi <think>blah</think> there"), "hi  there");
    }

    #[test]
    fn strip_think_multiple_blocks() {
        assert_eq!(strip_think_blocks("a<think>1</think>b<think>2</think>c"), "abc");
    }

    #[test]
    fn strip_think_unterminated_emits_as_is() {
        assert_eq!(strip_think_blocks("hi <think>unfinished"), "hi <think>unfinished");
    }

    #[test]
    fn strip_think_multiline_block() {
        assert_eq!(
            strip_think_blocks("a<think>\nlots\nof\nstuff\n</think>b"),
            "ab"
        );
    }

    #[test]
    fn strip_quotes_none() {
        assert_eq!(strip_wrapping_quotes("hello"), "hello");
    }

    #[test]
    fn strip_quotes_double() {
        assert_eq!(strip_wrapping_quotes("\"hello\""), "hello");
    }

    #[test]
    fn strip_quotes_single() {
        assert_eq!(strip_wrapping_quotes("'hello'"), "hello");
    }

    #[test]
    fn strip_quotes_mismatched_not_stripped() {
        assert_eq!(strip_wrapping_quotes("\"hello'"), "\"hello'");
    }

    #[test]
    fn strip_quotes_three_quote_chars_not_stripped() {
        // Quote count != 2 — preserve as-is (matches Python script behavior).
        assert_eq!(strip_wrapping_quotes("\"he\"llo"), "\"he\"llo");
    }

    #[test]
    fn strip_quotes_trims_whitespace_inside() {
        assert_eq!(strip_wrapping_quotes("  \"hello\"  "), "hello");
    }

    #[test]
    fn clean_output_strips_think_then_quotes() {
        let raw = "<think>internal</think>\"the answer\"";
        assert_eq!(clean_output(raw), "the answer");
    }

    #[test]
    fn parse_response_ok() {
        let body = r#"{"message":{"content":"the rewrite"}}"#;
        assert_eq!(parse_response(body).unwrap(), "the rewrite");
    }

    #[test]
    fn parse_response_missing_message_returns_parse_err() {
        let body = r#"{}"#;
        assert!(matches!(parse_response(body), Err(RewriteError::Parse(_))));
    }

    #[test]
    fn parse_response_missing_content_returns_parse_err() {
        let body = r#"{"message":{}}"#;
        assert!(matches!(parse_response(body), Err(RewriteError::Parse(_))));
    }

    #[test]
    fn parse_response_invalid_json_returns_parse_err() {
        assert!(matches!(parse_response("not json"), Err(RewriteError::Parse(_))));
    }

    #[test]
    fn parse_response_preserves_think_block_for_later_strip() {
        // parse_response is just JSON extraction. <think> stripping happens later.
        let body = r#"{"message":{"content":"<think>x</think>final"}}"#;
        assert_eq!(parse_response(body).unwrap(), "<think>x</think>final");
    }

    #[test]
    fn stderr_timeout_phrasing() {
        assert_eq!(
            RewriteError::Timeout.stderr_message(),
            "ERROR: Ollama request timed out"
        );
    }

    #[test]
    fn stderr_connection_refused_phrasing() {
        let msg = RewriteError::ConnectionRefused.stderr_message();
        assert_eq!(
            msg,
            "ERROR: Connection to Ollama refused; is 'ollama serve' running?"
        );
        // Swift heuristic in RewriterFlow.swift:75 keys on "Connection" (case-insensitive).
        assert!(msg.to_lowercase().contains("connection"));
    }

    #[test]
    fn stderr_empty_phrasing() {
        assert_eq!(
            RewriteError::Empty.stderr_message(),
            "ERROR: empty rewrite output"
        );
    }

    #[test]
    fn stderr_http_includes_inner_message() {
        let m = RewriteError::Http("500 boom".into()).stderr_message();
        assert!(m.starts_with("ERROR:"));
        assert!(m.contains("500 boom"));
    }

    #[test]
    fn stderr_parse_includes_inner_reason() {
        let m = RewriteError::Parse("missing message.content".into()).stderr_message();
        assert!(m.starts_with("ERROR:"));
        assert!(m.contains("missing message.content"));
    }

    #[test]
    fn build_payload_has_expected_shape() {
        let p = build_payload("rewrite me", "qwen3:8b", None);
        assert_eq!(p["model"], "qwen3:8b");
        assert_eq!(p["stream"], false);
        assert_eq!(p["think"], false);
        assert_eq!(p["options"]["temperature"], 0.2);
        let msgs = p["messages"].as_array().expect("messages array");
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0]["role"], "system");
        assert_eq!(msgs[1]["role"], "user");
        assert_eq!(msgs[1]["content"], "rewrite me");
        let sys_text = msgs[0]["content"].as_str().unwrap();
        assert!(sys_text.contains("prompt engineering assistant"));
        assert!(sys_text.contains("User-provided context"));
    }
    #[test]
    fn build_payload_uses_provided_model() {
        let p = build_payload("hi", "llama3.1:8b", None);
        assert_eq!(p["model"], "llama3.1:8b");
    }
    #[test]
    fn build_payload_prepends_context_block_to_user_message() {
        let p = build_payload("rewrite me", "qwen3:8b", Some("for my boss"));
        let content = p["messages"][1]["content"].as_str().unwrap();
        assert!(content.contains("[CONTEXT]"));
        assert!(content.contains("[/CONTEXT]"));
        assert!(content.contains("for my boss"));
        assert!(content.trim_end().ends_with("rewrite me"));
        assert_eq!(p["messages"].as_array().unwrap().len(), 2); // still ONE system msg
    }
    #[test]
    fn build_payload_blank_context_is_ignored() {
        let p = build_payload("rewrite me", "qwen3:8b", Some("   "));
        assert_eq!(p["messages"][1]["content"], "rewrite me");
    }

    #[test]
    fn parse_args_returns_model_when_present() {
        let args = vec!["owlet-rewriter".to_string(), "--model".to_string(), "llama3.1:8b".to_string()];
        let parsed = parse_args(&args).unwrap();
        assert_eq!(parsed.model, "llama3.1:8b");
        assert_eq!(parsed.context, None);
    }
    #[test]
    fn parse_args_defaults_model_when_absent() {
        let parsed = parse_args(&["owlet-rewriter".to_string()]).unwrap();
        assert_eq!(parsed.model, "qwen3:8b");
    }
    #[test]
    fn parse_args_returns_context_when_present() {
        let args = vec!["owlet-rewriter".to_string(), "--context".to_string(), "for my boss".to_string()];
        assert_eq!(parse_args(&args).unwrap().context, Some("for my boss".to_string()));
    }
    #[test]
    fn parse_args_model_and_context_together() {
        let args = vec!["owlet-rewriter".to_string(), "--model".to_string(), "m".to_string(),
                        "--context".to_string(), "c".to_string()];
        let parsed = parse_args(&args).unwrap();
        assert_eq!(parsed.model, "m");
        assert_eq!(parsed.context, Some("c".to_string()));
    }
    #[test]
    fn parse_args_errors_when_flag_has_no_value() {
        assert!(parse_args(&["owlet-rewriter".to_string(), "--context".to_string()]).is_err());
    }
    #[test]
    fn parse_args_errors_on_unknown_flag() {
        assert!(parse_args(&["owlet-rewriter".to_string(), "--nope".to_string(), "x".to_string()]).is_err());
    }
}
