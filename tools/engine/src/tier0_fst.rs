//! Tier 0 — instant word completion (design §3).
//!
//! On every keystroke: take the trailing partial word and return the suffix that
//! finishes the highest-frequency dictionary word starting with it. Pure prefix
//! completion over an `fst::Map<u64>` (value = frequency, for ranking); sub-ms and
//! runs off the model thread. Levenshtein fuzzy tolerance (external spec §5.1) is a
//! documented follow-up — kept out of v1 so a typo'd prefix can't silently turn a
//! completion into a correction (that is Tier 1's job).

use fst::automaton::Str;
use fst::{Automaton, IntoStreamer, Map, Streamer};

pub struct WordCompleter {
    map: Map<Vec<u8>>,
}

impl WordCompleter {
    /// Build from `(word, frequency)` pairs. Higher frequency ranks first; words are
    /// lowercased, sorted, and de-duplicated (first wins on a duplicate key).
    pub fn from_pairs(pairs: impl IntoIterator<Item = (String, u64)>) -> Result<Self, fst::Error> {
        let mut pairs: Vec<(String, u64)> = pairs
            .into_iter()
            .map(|(w, f)| (w.to_lowercase(), f))
            .collect();
        pairs.sort_by(|a, b| a.0.cmp(&b.0));
        pairs.dedup_by(|a, b| a.0 == b.0);
        let map = Map::from_iter(pairs)?;
        Ok(Self { map })
    }

    /// Parse a newline-delimited word list where line order is descending frequency
    /// (first line = most frequent). Blank lines and `#` comments are skipped.
    pub fn from_wordlist(text: &str) -> Result<Self, fst::Error> {
        let words: Vec<&str> = text
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .collect();
        let n = words.len() as u64;
        let pairs = words
            .into_iter()
            .enumerate()
            .map(|(i, w)| (w.to_string(), n - i as u64));
        Self::from_pairs(pairs)
    }

    /// Complete the trailing partial word of `prefix`. Returns the suffix to append
    /// at the caret (e.g. `"I am goi"` → `"ng"`), or `None` when there is nothing to
    /// add: the prefix ends in whitespace/punctuation, there is no matching word, or
    /// the partial word is already complete.
    pub fn complete_prefix(&self, prefix: &str) -> Option<String> {
        self.complete_word(trailing_partial_word(prefix))
    }

    fn complete_word(&self, partial: &str) -> Option<String> {
        if partial.is_empty() {
            return None;
        }
        let needle = partial.to_lowercase();
        let mut stream = self.map.search(Str::new(&needle).starts_with()).into_stream();
        let mut best: Option<(Vec<u8>, u64)> = None;
        while let Some((key, value)) = stream.next() {
            // key.len() == needle.len() is the exact match (nothing to append);
            // a prefix match guarantees key.len() >= needle.len().
            if key.len() <= needle.len() {
                continue;
            }
            let better = match &best {
                Some((_, best_freq)) => value > *best_freq,
                None => true,
            };
            if better {
                best = Some((key.to_vec(), value));
            }
        }
        let word = String::from_utf8(best?.0).ok()?;
        // The dictionary word is lowercased and starts with `needle`, so slicing at
        // the needle's byte length lands on a char boundary. The returned suffix is
        // appended after the caret, so the user's own casing of the partial stands.
        Some(word[needle.len()..].to_string())
    }
}

/// The trailing run of word characters in `prefix` (alphanumerics + apostrophe).
/// Empty when `prefix` ends in whitespace or punctuation. ASCII-oriented for v1.
pub fn trailing_partial_word(prefix: &str) -> &str {
    let start = prefix
        .char_indices()
        .rev()
        .take_while(|(_, c)| c.is_alphanumeric() || *c == '\'')
        .last()
        .map(|(i, _)| i)
        .unwrap_or(prefix.len());
    &prefix[start..]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> WordCompleter {
        WordCompleter::from_pairs([
            ("going".to_string(), 100),
            ("good".to_string(), 90),
            ("go".to_string(), 80),
            ("hello".to_string(), 70),
            ("help".to_string(), 60),
            ("helicopter".to_string(), 10),
        ])
        .unwrap()
    }

    #[test]
    fn trailing_word_extraction() {
        assert_eq!(trailing_partial_word("I am goi"), "goi");
        assert_eq!(trailing_partial_word("going "), "");
        assert_eq!(trailing_partial_word("end."), "");
        assert_eq!(trailing_partial_word(""), "");
        assert_eq!(trailing_partial_word("don'"), "don'");
        assert_eq!(trailing_partial_word("a"), "a");
    }

    #[test]
    fn completes_to_highest_frequency_word() {
        // "goi" → only "going" matches → "ng".
        assert_eq!(fixture().complete_prefix("I am goi"), Some("ng".to_string()));
    }

    #[test]
    fn ranks_by_frequency_on_shared_prefix() {
        // "go" prefixes "going"(100), "good"(90), and "go"(exact, skipped).
        assert_eq!(fixture().complete_prefix("go"), Some("ing".to_string()));
        // "hel" prefixes "hello"(70), "help"(60), "helicopter"(10) → "hello".
        assert_eq!(fixture().complete_prefix("hel"), Some("lo".to_string()));
    }

    #[test]
    fn no_completion_when_word_finished_or_unknown() {
        assert_eq!(fixture().complete_prefix("going "), None); // trailing space
        assert_eq!(fixture().complete_prefix("xyz"), None); // not in dictionary
        assert_eq!(fixture().complete_prefix(""), None); // empty
        assert_eq!(fixture().complete_prefix("going"), None); // already complete (exact)
    }

    #[test]
    fn case_insensitive_match_preserves_caret_casing() {
        // Capitalized partial still matches; the lowercase suffix appends cleanly.
        assert_eq!(fixture().complete_prefix("Goi"), Some("ng".to_string()));
        assert_eq!(fixture().complete_prefix("The Goi"), Some("ng".to_string()));
    }

    #[test]
    fn from_wordlist_ranks_by_line_order() {
        let wl = WordCompleter::from_wordlist("# header\ngoing\ngood\n\ngo\n").unwrap();
        // "going" appears before "good", so it ranks higher on the "go" prefix.
        assert_eq!(wl.complete_prefix("go"), Some("ing".to_string()));
    }
}
