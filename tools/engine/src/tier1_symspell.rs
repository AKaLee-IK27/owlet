//! Tier 1 — Recorrect (fix spelling / obvious errors), design §3.
//!
//! On a word boundary, take the word the user just finished and, if it isn't in the
//! dictionary, offer the closest dictionary word (edit distance ≤ 2, frequency-ranked)
//! as a replacement spanning that word.
//!
//! Implementation: brute-force bounded Levenshtein over the dictionary. For the small
//! starter dictionary this is sub-millisecond; when the dictionary grows large, switch
//! to SymSpell-style precomputed deletes (the external spec's `symspell` crate) — the
//! `correct_last_word` interface stays the same.

use std::collections::HashSet;

/// A proposed replacement: the half-open character range `[start, end)` of the
/// misspelled word *within the prefix the engine received*, and the correction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Correction {
    pub start: u32,
    pub end: u32,
    pub text: String,
}

pub struct SpellCorrector {
    /// (lowercased word, frequency) for ranking corrections.
    words: Vec<(String, u64)>,
    /// Lowercased dictionary for the "is this spelled correctly?" check.
    known: HashSet<String>,
}

impl SpellCorrector {
    pub fn from_pairs(pairs: impl IntoIterator<Item = (String, u64)>) -> Self {
        let words: Vec<(String, u64)> = pairs
            .into_iter()
            .map(|(w, f)| (w.to_lowercase(), f))
            .collect();
        let known = words.iter().map(|(w, _)| w.clone()).collect();
        Self { words, known }
    }

    /// Parse a newline-delimited word list; line order = descending frequency. Blank
    /// lines and `#` comments are skipped. (Same format as the Tier 0 dictionary.)
    pub fn from_wordlist(text: &str) -> Self {
        let words: Vec<&str> = text
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .collect();
        let n = words.len() as u64;
        Self::from_pairs(
            words
                .into_iter()
                .enumerate()
                .map(|(i, w)| (w.to_string(), n - i as u64)),
        )
    }

    /// Correct the last completed word in `prefix` (which ends at a word boundary).
    /// Returns `None` when there is no word, it is already spelled correctly, or no
    /// dictionary word lies within edit distance 2.
    pub fn correct_last_word(&self, prefix: &str) -> Option<Correction> {
        let (start, end, word) = last_completed_word(prefix)?;
        let lower = word.to_lowercase();
        if self.known.contains(&lower) {
            return None; // already correct
        }
        let mut best: Option<(&str, u64, usize)> = None; // (word, freq, distance)
        for (candidate, freq) in &self.words {
            let Some(distance) = bounded_levenshtein(&lower, candidate, 2) else { continue };
            let better = match best {
                Some((_, best_freq, best_dist)) => {
                    distance < best_dist || (distance == best_dist && *freq > best_freq)
                }
                None => true,
            };
            if better {
                best = Some((candidate, *freq, distance));
            }
        }
        let (correction, _, _) = best?;
        Some(Correction {
            start: start as u32,
            end: end as u32,
            text: match_leading_case(&word, correction),
        })
    }
}

/// Straight (U+0027) and smart (U+2019) apostrophes. macOS Smart Quotes (on by
/// default in TextEdit/Notes/Mail) substitute U+2019, so a contraction reaches the
/// engine as `don\u{2019}t` — both must count inside a word.
fn is_apostrophe(c: char) -> bool {
    c == '\'' || c == '\u{2019}'
}

/// The trailing completed word in `prefix`: the last run of alphanumerics, plus any
/// *interior* apostrophes (flanked by alphanumerics, so "don't"/"don’t" stay one
/// word) but excluding leading/trailing quotes and punctuation. Returns its
/// `[start, end)` **character** offsets (Unicode scalars) in `prefix` and the word.
/// `None` if there is no alphanumeric character.
fn last_completed_word(prefix: &str) -> Option<(usize, usize, String)> {
    let chars: Vec<char> = prefix.chars().collect();
    // End just past the last alphanumeric — trailing apostrophes/quotes/punct excluded.
    let mut end = chars.len();
    while end > 0 && !chars[end - 1].is_alphanumeric() {
        end -= 1;
    }
    if end == 0 {
        return None;
    }
    // Walk back over alphanumerics and interior apostrophes; a leading apostrophe
    // (no alphanumeric before it) ends the word, so it isn't captured.
    let mut start = end;
    while start > 0 {
        let c = chars[start - 1];
        let interior_apostrophe =
            is_apostrophe(c) && start >= 2 && chars[start - 2].is_alphanumeric();
        if c.is_alphanumeric() || interior_apostrophe {
            start -= 1;
        } else {
            break;
        }
    }
    Some((start, end, chars[start..end].iter().collect()))
}

/// If `original` starts with an uppercase letter, capitalize `correction`'s first
/// letter so a corrected `"Beleive"` becomes `"Believe"`, not `"believe"`.
fn match_leading_case(original: &str, correction: &str) -> String {
    let original_upper = original.chars().next().is_some_and(|c| c.is_uppercase());
    if !original_upper {
        return correction.to_string();
    }
    let mut chars = correction.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// Levenshtein distance, returning `None` as soon as it is known to exceed `max`.
fn bounded_levenshtein(a: &str, b: &str, max: usize) -> Option<usize> {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let (n, m) = (a.len(), b.len());
    if n.abs_diff(m) > max {
        return None;
    }
    let mut prev: Vec<usize> = (0..=m).collect();
    let mut curr = vec![0usize; m + 1];
    for i in 1..=n {
        curr[0] = i;
        let mut row_min = curr[0];
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            curr[j] = (prev[j] + 1).min(curr[j - 1] + 1).min(prev[j - 1] + cost);
            row_min = row_min.min(curr[j]);
        }
        if row_min > max {
            return None; // every cell in this row already exceeds the budget
        }
        std::mem::swap(&mut prev, &mut curr);
    }
    let distance = prev[m];
    (distance <= max).then_some(distance)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> SpellCorrector {
        SpellCorrector::from_pairs([
            ("because".to_string(), 100),
            ("people".to_string(), 90),
            ("would".to_string(), 80),
            ("their".to_string(), 70),
            ("there".to_string(), 60),
        ])
    }

    #[test]
    fn extracts_last_completed_word() {
        assert_eq!(last_completed_word("I beleive "), Some((2, 9, "beleive".to_string())));
        assert_eq!(last_completed_word("the cat sat."), Some((8, 11, "sat".to_string())));
        assert_eq!(last_completed_word("   "), None);
        assert_eq!(last_completed_word(""), None);
    }

    #[test]
    fn keeps_contractions_whole_including_smart_quotes() {
        // Interior apostrophe (straight and the macOS smart quote) stays in the word —
        // it must NOT split into a trailing "t".
        assert_eq!(last_completed_word("don't "), Some((0, 5, "don't".to_string())));
        assert_eq!(last_completed_word("don\u{2019}t "), Some((0, 5, "don\u{2019}t".to_string())));
    }

    #[test]
    fn drops_bracketing_quotes() {
        // Leading/trailing quotes are not part of the word.
        assert_eq!(last_completed_word("'hello' "), Some((1, 6, "hello".to_string())));
    }

    #[test]
    fn smart_quote_contraction_is_not_falsely_corrected() {
        // Regression for the review's HIGH: "don’t" must not become a "t" → "to" fix.
        assert!(fixture().correct_last_word("i don\u{2019}t ").is_none());
        assert!(fixture().correct_last_word("don't ").is_none());
    }

    #[test]
    fn corrects_a_close_misspelling() {
        // "peple" → "people" (one deletion).
        let c = fixture().correct_last_word("the peple ").unwrap();
        assert_eq!(c, Correction { start: 4, end: 9, text: "people".to_string() });
    }

    #[test]
    fn corrects_within_edit_distance_two() {
        // "wuld" → "would" (insert o, then... distance 1 actually). Use "wld" → "would"? dist 2.
        let c = fixture().correct_last_word("i wuld ").unwrap();
        assert_eq!(c.text, "would");
        assert_eq!((c.start, c.end), (2, 6));
    }

    #[test]
    fn leaves_correctly_spelled_words_alone() {
        assert!(fixture().correct_last_word("the people ").is_none());
        assert!(fixture().correct_last_word("there ").is_none());
    }

    #[test]
    fn no_correction_when_too_far() {
        // "xyzzy" is edit distance > 2 from every dictionary word.
        assert!(fixture().correct_last_word("the xyzzy ").is_none());
    }

    #[test]
    fn preserves_leading_capital() {
        let c = fixture().correct_last_word("Peple ").unwrap();
        assert_eq!(c.text, "People");
    }

    #[test]
    fn ranks_by_distance_then_frequency() {
        // "ther" is distance 1 from both "their" and "there"; pick the higher-frequency
        // one ("their", 70 > 60).
        let c = fixture().correct_last_word("ther ").unwrap();
        assert_eq!(c.text, "their");
    }
}
