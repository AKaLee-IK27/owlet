#[derive(Debug)]
enum RewriteError {
    Timeout,
    ConnectionRefused,
    Http(String),
    Parse(String),
    Empty,
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

fn main() {
    eprintln!("owlet-rewriter: stub, not yet implemented");
    std::process::exit(1);
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
