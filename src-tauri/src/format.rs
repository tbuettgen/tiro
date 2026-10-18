//! The delivered-text formatting pipeline (spec/FLOW_FEATURES.md, "The
//! formatting pipeline", steps 1-10): whitespace, whole-take snippets,
//! spoken commands ("new line", "comma", "scratch that"), filler removal,
//! the light rules, writing style, then corrections and inline snippets.
//!
//! This is the contract shared with the iOS `SmartFormatter`: both test
//! suites run `spec/format_cases.json`, so the two formatters can never
//! drift apart. Formatting only ever shapes the DELIVERED copy (clipboard,
//! paste) — the verbatim transcript is always what gets logged as `text`.

use std::sync::OnceLock;

use regex::{Captures, Regex};

use crate::config::ConfigStore;
use crate::vocab;

/// `clipboard_cleanup`: how much the delivered copy is tidied.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cleanup {
    /// Verbatim (whitespace collapsed); corrections and snippets still apply.
    None,
    Light,
    /// Light, plus um/uh/erm/hmm stripped.
    Fillers,
}

impl Cleanup {
    /// The config value -> mode. Anything unknown gets the light rules, the
    /// original's `cleanup_text` behavior.
    pub fn from_cfg(val: &str) -> Self {
        match val.trim().to_lowercase().as_str() {
            "none" => Cleanup::None,
            "fillers" => Cleanup::Fillers,
            _ => Cleanup::Light,
        }
    }
}

/// `style`: the writing register of the delivered copy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Style {
    Formal,
    Casual,
    VeryCasual,
}

impl Style {
    /// The config value -> style; unknown values are formal (the no-op).
    pub fn from_cfg(val: &str) -> Self {
        match val.trim().to_lowercase().replace('-', "_").as_str() {
            "casual" => Style::Casual,
            "very_casual" | "verycasual" => Style::VeryCasual,
            _ => Style::Formal,
        }
    }

    /// The canonical config / bridge spelling.
    pub fn as_str(self) -> &'static str {
        match self {
            Style::Formal => "formal",
            Style::Casual => "casual",
            Style::VeryCasual => "very_casual",
        }
    }
}

/// Everything `format_text` needs. The two lists come from
/// `corrections.txt` / `snippets.txt` (vocab.rs), in file order.
#[derive(Debug, Clone)]
pub struct FormatOptions {
    pub cleanup: Cleanup,
    pub spoken_commands: bool,
    pub style: Style,
    pub corrections: Vec<(String, String)>,
    pub snippets: Vec<(String, String)>,
}

impl Default for FormatOptions {
    /// The spec defaults (= a fresh config.ini).
    fn default() -> Self {
        Self {
            cleanup: Cleanup::Light,
            spoken_commands: true,
            style: Style::Formal,
            corrections: Vec::new(),
            snippets: Vec::new(),
        }
    }
}

impl FormatOptions {
    /// The config-backed options. The two lists are left empty: callers
    /// read the vocabulary files AFTER dropping the cfg lock (filesystem
    /// work never happens under it — see the engine LOCK LAW in flow.rs).
    pub fn from_config(cfg: &ConfigStore) -> Self {
        Self {
            cleanup: Cleanup::from_cfg(&cfg.get("clipboard_cleanup")),
            spoken_commands: cfg.get_bool("spoken_commands"),
            style: Style::from_cfg(&cfg.get("style")),
            corrections: Vec::new(),
            snippets: Vec::new(),
        }
    }
}

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("format regex"))
}

/// Collapse every whitespace run to one space and trim (step 1).
fn collapse_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Trim spaces/tabs (never newlines) at both ends of every line.
fn trim_lines(s: &str) -> String {
    s.split('\n')
        .map(|ln| ln.trim_matches([' ', '\t']))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Runs of spaces/tabs -> one space.
fn collapse_blanks(s: &str) -> String {
    static BLANKS: OnceLock<Regex> = OnceLock::new();
    re(&BLANKS, r"[ \t]+").replace_all(s, " ").into_owned()
}

/// Spaces/tabs before `,.;:!?` removed.
fn tighten_punct(s: &str) -> String {
    static SPACE_PUNCT: OnceLock<Regex> = OnceLock::new();
    re(&SPACE_PUNCT, r"[ \t]+([,.;:!?])")
        .replace_all(s, "$1")
        .into_owned()
}

/// The whole-take snippet key (step 2): lowercase, letters/digits/spaces
/// only, spaces collapsed, trimmed.
fn snippet_key(s: &str) -> String {
    let kept: String = s
        .to_lowercase()
        .chars()
        .map(|c| if c.is_whitespace() { ' ' } else { c })
        .filter(|c| c.is_alphanumeric() || *c == ' ')
        .collect();
    collapse_ws(&kept)
}

/// Words that make a following "period" the ordinary noun ("the trial
/// period", "a grace period") rather than the spoken mark.
const PERIOD_NOUN_CUES: &[&str] = &[
    "a",
    "an",
    "the",
    "this",
    "that",
    "each",
    "every",
    "any",
    "some",
    "which",
    "what",
    "trial",
    "grace",
    "waiting",
    "cooling",
    "probation",
    "billing",
];

/// Is the word right before byte offset `at` (ignoring punctuation and
/// spaces) one of the period-noun cues?
fn period_is_a_word(text: &str, at: usize) -> bool {
    let before = text[..at].trim_end_matches(|c: char| !c.is_alphanumeric());
    let start = before
        .char_indices()
        .rev()
        .take_while(|(_, c)| c.is_alphanumeric() || *c == '\'' || *c == '\u{2019}')
        .last()
        .map_or(before.len(), |(i, _)| i);
    let word = before[start..].to_lowercase();
    PERIOD_NOUN_CUES.contains(&word.as_str())
}

/// Step 4: spoken commands — line breaks, punctuation, then deletion, then
/// the spacing tidy. May return "" (the take was only "scratch that").
fn spoken_commands(text: &str) -> String {
    static PARAGRAPH: OnceLock<Regex> = OnceLock::new();
    static LINE: OnceLock<Regex> = OnceLock::new();
    static PUNCT: OnceLock<Regex> = OnceLock::new();
    static DELETE: OnceLock<Regex> = OnceLock::new();
    static MANY_NEWLINES: OnceLock<Regex> = OnceLock::new();

    // 1. Line breaks: swallow the spaces before the command and any
    //    punctuation + spaces after it; punctuation BEFORE it is kept.
    let mut t = re(&PARAGRAPH, r"(?i)[ \t]*\bnew[ \t]+paragraph\b[,.;:!? \t]*")
        .replace_all(text, "\n\n")
        .into_owned();
    t = re(&LINE, r"(?i)[ \t]*\bnew[ \t]+line\b[,.;:!? \t]*")
        .replace_all(&t, "\n")
        .into_owned();

    // 2. Punctuation: the match swallows spaces and marks on BOTH sides, so
    //    a mark Whisper already wrote never doubles ("Hello, comma, how").
    let src = t;
    t = re(
        &PUNCT,
        r"(?i)[ \t,.;:!?]*\b(?P<cmd>question[ \t]+mark|exclamation[ \t]+(?:point|mark)|full[ \t]+stop|semicolon|colon|comma|period)\b[ \t,.;:!?]*",
    )
    .replace_all(&src, |caps: &Captures| {
        let whole = caps.get(0).expect("match");
        let cmd = caps["cmd"].to_lowercase();
        let mark = match cmd.split_whitespace().next().unwrap_or_default() {
            "question" => "?",
            "exclamation" => "!",
            "semicolon" => ";",
            "colon" => ":",
            "comma" => ",",
            "period" if period_is_a_word(&src, whole.start()) => {
                // the ordinary word: leave the whole match untouched
                return whole.as_str().to_string();
            }
            _ => ".", // full stop, period
        };
        format!("{mark} ")
    })
    .into_owned();

    // 3. Deletion: the first command wipes back to the nearest sentence end
    //    or line start; repeat until none are left.
    let delete = re(
        &DELETE,
        r"(?i)\b(?:scratch|delete|strike)[ \t]+that\b[,.;:!? \t]*",
    );
    while let Some(m) = delete.find(&t) {
        let (start, end) = (m.start(), m.end());
        let cut = t[..start].rfind(['.', '!', '?', '\n']).map_or(0, |i| i + 1);
        t.replace_range(cut..end, " ");
    }

    // Tidy: spacing, line edges, at most one blank line in a row.
    t = tighten_punct(&collapse_blanks(&t));
    t = trim_lines(&t);
    t = re(&MANY_NEWLINES, r"\n{3,}")
        .replace_all(&t, "\n\n")
        .into_owned();
    t.trim().to_string()
}

/// Step 5: strip um/uh/erm/hmm (spaces and tabs after them only — a line
/// break next to a filler survives).
fn strip_fillers(text: &str) -> String {
    static FILLER: OnceLock<Regex> = OnceLock::new();
    let t = re(&FILLER, r"(?i)\b(um+|uh+|erm+|hmm+)\b,?[ \t]*").replace_all(text, "");
    trim_lines(&collapse_blanks(&t)).trim().to_string()
}

/// Uppercase the first character of `line` (no-op for non-letters).
fn upper_first(line: &str) -> String {
    let mut chars = line.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// Step 6: the light rules (the original's `cleanup_text`, line-aware).
fn light_rules(text: &str) -> String {
    static STANDALONE_I: OnceLock<Regex> = OnceLock::new();
    let t = tighten_punct(text);
    let t = re(&STANDALONE_I, r"\bi\b").replace_all(&t, "I");
    let mut t = t
        .split('\n')
        .map(upper_first)
        .collect::<Vec<_>>()
        .join("\n");
    if !matches!(t.chars().last(), Some('.' | '!' | '?')) {
        t.push('.');
    }
    t
}

fn is_word_char(c: char) -> bool {
    c.is_alphabetic() || c == '\'' || c == '\u{2019}'
}

/// `very_casual`: lowercase the first letter of each sentence-start word
/// unless it is "I"/"I'…" or has capitals past its first letter (NASA).
fn lower_sentence_starts(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut starts = vec![0];
    for (i, &c) in chars.iter().enumerate() {
        if c == '\n' {
            starts.push(i + 1);
        } else if matches!(c, '.' | '!' | '?') && chars.get(i + 1) == Some(&' ') {
            starts.push(i + 2);
        }
    }
    let mut lower = vec![false; chars.len()];
    for s in starts {
        let end = (s..chars.len())
            .find(|&j| !is_word_char(chars[j]))
            .unwrap_or(chars.len());
        if end <= s || !chars[s].is_alphabetic() {
            continue;
        }
        let word: String = chars[s..end].iter().collect();
        if word == "I" || word.starts_with("I'") || word.starts_with("I\u{2019}") {
            continue;
        }
        if chars[s + 1..end]
            .iter()
            .filter(|c| c.is_alphabetic())
            .all(|c| c.is_lowercase())
        {
            lower[s] = true;
        }
    }
    let mut out = String::with_capacity(text.len());
    for (c, low) in chars.into_iter().zip(lower) {
        if low {
            out.extend(c.to_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

/// Step 7: the writing style.
fn apply_style(text: &str, style: Style) -> String {
    let mut t = text.to_string();
    if style == Style::Formal {
        return t;
    }
    if t.ends_with('.') && !t.ends_with("..") {
        t.pop();
    }
    if style == Style::VeryCasual {
        t = lower_sentence_starts(&t);
    }
    t
}

/// `format(verbatim, options)`: the delivered copy of a take. Returns ""
/// only for an empty take or one that spoken commands deleted entirely
/// ("scratch that"); an all-filler take comes back as said.
pub fn format_text(verbatim: &str, opts: &FormatOptions) -> String {
    // 1. Whitespace.
    let said = collapse_ws(verbatim);
    if said.is_empty() {
        return String::new();
    }
    // 2. Whole-take snippet: the expansion exactly as saved, nothing else.
    let key = snippet_key(&said);
    for (trigger, expansion) in &opts.snippets {
        let trig = snippet_key(trigger);
        if !trig.is_empty() && trig == key {
            return expansion.clone();
        }
    }
    // 3. cleanup = none skips straight to corrections + snippets.
    let mut text = said.clone();
    if opts.cleanup != Cleanup::None {
        // 4. Spoken commands.
        if opts.spoken_commands {
            text = spoken_commands(&text);
            if text.is_empty() {
                return String::new();
            }
        }
        // 5. Fillers — an all-filler take is delivered as said (step-1
        //    text, no light rules or style), never lost.
        let mut as_said = false;
        if opts.cleanup == Cleanup::Fillers {
            text = strip_fillers(&text);
            if text.is_empty() {
                text = said;
                as_said = true;
            }
        }
        if !as_said {
            // 6. Light rules, 7. style.
            text = apply_style(&light_rules(&text), opts.style);
        }
    }
    // 9. Corrections (blank result keeps the pre-correction text).
    let text = vocab::apply_corrections(&text, &opts.corrections);
    // 10. Inline snippets, same matching rule.
    vocab::replace_phrases(&text, &opts.snippets)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const CASES: &str = include_str!("../../spec/format_cases.json");

    fn pairs(v: &Value) -> Vec<(String, String)> {
        v.as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|p| {
                        let p = p.as_array()?;
                        Some((p.first()?.as_str()?.into(), p.get(1)?.as_str()?.into()))
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Build options from the vectors' `defaults` overlaid with a case's
    /// `options` — key names are the spec's option names.
    fn options(defaults: &Value, over: Option<&Value>) -> FormatOptions {
        let pick = |key: &str| -> Value {
            over.and_then(|o| o.get(key))
                .or_else(|| defaults.get(key))
                .cloned()
                .unwrap_or(Value::Null)
        };
        FormatOptions {
            cleanup: Cleanup::from_cfg(pick("cleanup").as_str().unwrap_or("light")),
            spoken_commands: pick("spoken_commands").as_bool().unwrap_or(true),
            style: Style::from_cfg(pick("style").as_str().unwrap_or("formal")),
            corrections: pairs(&pick("corrections")),
            snippets: pairs(&pick("snippets")),
        }
    }

    #[test]
    fn shared_spec_vectors_all_pass() {
        let doc: Value = serde_json::from_str(CASES).expect("format_cases.json parses");
        let defaults = &doc["defaults"];
        let cases = doc["cases"].as_array().expect("cases array");
        assert!(!cases.is_empty(), "no vectors loaded");
        let mut failures = Vec::new();
        for case in cases {
            let name = case["name"].as_str().unwrap_or("?");
            let input = case["input"].as_str().expect("input");
            let expected = case["expected"].as_str().expect("expected");
            let got = format_text(input, &options(defaults, case.get("options")));
            if got != expected {
                failures.push(format!(
                    "  [{name}]\n    input:    {input:?}\n    expected: {expected:?}\n    got:      {got:?}"
                ));
            }
        }
        assert!(
            failures.is_empty(),
            "{} of {} format vectors failed:\n{}",
            failures.len(),
            cases.len(),
            failures.join("\n")
        );
    }

    #[test]
    fn option_parsing_is_forgiving() {
        assert_eq!(Cleanup::from_cfg("none"), Cleanup::None);
        assert_eq!(Cleanup::from_cfg("FILLERS"), Cleanup::Fillers);
        assert_eq!(Cleanup::from_cfg("banana"), Cleanup::Light);
        assert_eq!(Style::from_cfg("very-casual"), Style::VeryCasual);
        assert_eq!(Style::from_cfg("Casual"), Style::Casual);
        assert_eq!(Style::from_cfg(""), Style::Formal);
        for s in [Style::Formal, Style::Casual, Style::VeryCasual] {
            assert_eq!(Style::from_cfg(s.as_str()), s, "round trip");
        }
    }

    #[test]
    fn spoken_commands_stay_whole_word() {
        let opts = FormatOptions::default();
        // "commas", "periodic", "newline" are not commands
        assert_eq!(
            format_text("periodic commas on a newline", &opts),
            "Periodic commas on a newline."
        );
        // "a period" is the noun, even mid-sentence
        assert_eq!(
            format_text("wait a period of time", &opts),
            "Wait a period of time."
        );
    }

    #[test]
    fn whitespace_inside_two_word_commands_is_flexible() {
        let opts = FormatOptions::default();
        assert_eq!(
            format_text("one new \t paragraph two", &opts),
            "One\n\nTwo."
        );
        assert_eq!(format_text("ok question   mark", &opts), "Ok?");
    }

    #[test]
    fn empty_trigger_never_matches_a_punctuation_take() {
        let opts = FormatOptions {
            snippets: vec![("!!".into(), "boom".into())],
            ..FormatOptions::default()
        };
        assert_eq!(format_text("?", &opts), "?");
    }

    #[test]
    fn config_backed_options_follow_the_keys() {
        let dir = tempfile::TempDir::new().unwrap();
        let mut cfg = ConfigStore::load(dir.path().join("config.ini"), dir.path());
        let opts = FormatOptions::from_config(&cfg);
        assert_eq!(opts.cleanup, Cleanup::Light);
        assert!(opts.spoken_commands);
        assert_eq!(opts.style, Style::Formal);
        cfg.set("clipboard_cleanup", "fillers");
        cfg.set("spoken_commands", "false");
        cfg.set("style", "very_casual");
        let opts = FormatOptions::from_config(&cfg);
        assert_eq!(opts.cleanup, Cleanup::Fillers);
        assert!(!opts.spoken_commands);
        assert_eq!(opts.style, Style::VeryCasual);
    }
}
