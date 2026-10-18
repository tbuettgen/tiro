//! Dictation stats for the Transcribe page's strip (spec/FLOW_FEATURES.md,
//! "Stats"), computed from every JSONL day in the transcript folder:
//!
//! - words: whitespace-separated tokens of `clean` (or `text` when `clean`
//!   is empty), summed over all records
//! - takes: number of records
//! - WPM: words / total `secs` x 60, rounded (0 with no seconds)
//! - time saved: words at a 40 WPM typing speed minus the time spent
//!   talking, floored at 0, in minutes
//! - streak: consecutive days, ending today or yesterday, with a record
//!
//! Read-only and purely local, like everything else in the store.

use std::collections::HashSet;

use chrono::{Days, Local, NaiveDate};
use serde_json::{json, Value};

use crate::config::ConfigStore;
use crate::store::{self, Rec};

/// Typing speed the "time saved" figure is measured against.
pub const TYPING_WPM: f64 = 40.0;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Stats {
    pub words: u64,
    pub takes: u64,
    pub wpm: u64,
    pub minutes_saved: f64,
    pub streak: u64,
}

impl Stats {
    /// The bridge shape (`get_stats`). Minutes are rounded to one decimal
    /// here; the panel picks its own display unit.
    pub fn to_json(&self) -> Value {
        json!({
            "words": self.words,
            "takes": self.takes,
            "wpm": self.wpm,
            "minutesSaved": (self.minutes_saved * 10.0).round() / 10.0,
            "streak": self.streak,
        })
    }
}

/// The words a record contributes: its delivered copy, else the verbatim.
fn record_words(rec: &Rec) -> u64 {
    let shown = if rec.clean.is_empty() {
        &rec.text
    } else {
        &rec.clean
    };
    shown.split_whitespace().count() as u64
}

/// The pure math over `(day, records)` pairs, with `today` injected so the
/// streak is testable. Days that hold no records never count toward the
/// streak (an empty or all-corrupt file is not a dictation day).
pub fn compute(days: &[(NaiveDate, Vec<Rec>)], today: NaiveDate) -> Stats {
    let mut words = 0u64;
    let mut takes = 0u64;
    let mut secs = 0f64;
    let mut active: HashSet<NaiveDate> = HashSet::new();
    for (day, recs) in days {
        if !recs.is_empty() {
            active.insert(*day);
        }
        for rec in recs {
            takes += 1;
            words += record_words(rec);
            if rec.secs.is_finite() && rec.secs > 0.0 {
                secs += rec.secs;
            }
        }
    }
    let wpm = if secs > 0.0 {
        (words as f64 / secs * 60.0).round() as u64
    } else {
        0
    };
    let minutes_saved = (words as f64 / TYPING_WPM - secs / 60.0).max(0.0);
    // The streak may end yesterday: today simply has no take YET.
    let mut cursor = if active.contains(&today) {
        Some(today)
    } else {
        today.checked_sub_days(Days::new(1))
    };
    let mut streak = 0u64;
    while let Some(day) = cursor.filter(|d| active.contains(d)) {
        streak += 1;
        cursor = day.checked_sub_days(Days::new(1));
    }
    Stats {
        words,
        takes,
        wpm,
        minutes_saved,
        streak,
    }
}

/// `get_stats`: every transcript day on disk, as of the local today.
pub fn collect(cfg: &ConfigStore) -> Stats {
    let days: Vec<(NaiveDate, Vec<Rec>)> = store::list_days(cfg)
        .into_iter()
        .filter_map(|day| {
            let date = NaiveDate::parse_from_str(&day, "%Y-%m-%d").ok()?;
            Some((date, store::read_day_entries(cfg, &day, usize::MAX)))
        })
        .collect();
    compute(&days, Local::now().date_naive())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn rec(text: &str, clean: &str, secs: f64) -> Rec {
        Rec {
            ts: "2026-07-27T10:00:00".into(),
            text: text.into(),
            clean: clean.into(),
            mic: String::new(),
            model: "base.en".into(),
            device: "cpu".into(),
            secs,
        }
    }

    fn d(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    #[test]
    fn words_takes_wpm_and_time_saved() {
        let days = vec![(
            d("2026-07-27"),
            vec![
                // clean preferred: 4 words
                rec("one two three", "One, two, three, four.", 3.0),
                // clean empty -> verbatim: 2 words
                rec("hello there", "", 3.0),
            ],
        )];
        let s = compute(&days, d("2026-07-27"));
        assert_eq!(s.takes, 2);
        assert_eq!(s.words, 6);
        assert_eq!(s.wpm, 60, "6 words over 6 s");
        // 6 words at 40 WPM = 0.15 min, minus 0.1 min talking = 0.05
        assert!((s.minutes_saved - 0.05).abs() < 1e-9, "{}", s.minutes_saved);
    }

    #[test]
    fn no_seconds_means_zero_wpm_and_saved_floors_at_zero() {
        let s = compute(
            &[(d("2026-07-27"), vec![rec("a b c", "", 0.0)])],
            d("2026-07-27"),
        );
        assert_eq!(s.wpm, 0);
        // talking far slower than typing never goes negative
        let slow = compute(
            &[(d("2026-07-27"), vec![rec("just two", "", 600.0)])],
            d("2026-07-27"),
        );
        assert_eq!(slow.minutes_saved, 0.0);
        assert_eq!(compute(&[], d("2026-07-27")), Stats::default());
    }

    #[test]
    fn wpm_rounds_to_nearest() {
        // 1 word in 7 s = 8.57 WPM -> 9
        let s = compute(
            &[(d("2026-07-27"), vec![rec("a", "", 7.0)])],
            d("2026-07-27"),
        );
        assert_eq!(s.wpm, 9);
    }

    #[test]
    fn streak_ends_today_or_yesterday() {
        let at = |list: &[&str]| -> Vec<(NaiveDate, Vec<Rec>)> {
            list.iter()
                .map(|s| (d(s), vec![rec("x", "", 1.0)]))
                .collect()
        };
        let today = d("2026-07-27");
        // today + two days before, then a gap
        let s = compute(
            &at(&["2026-07-27", "2026-07-26", "2026-07-25", "2026-07-23"]),
            today,
        );
        assert_eq!(s.streak, 3);
        // nothing today yet: the streak through yesterday still stands
        assert_eq!(compute(&at(&["2026-07-26", "2026-07-25"]), today).streak, 2);
        // last take two days ago: streak broken
        assert_eq!(compute(&at(&["2026-07-25", "2026-07-24"]), today).streak, 0);
        // across a month boundary
        assert_eq!(
            compute(
                &at(&["2026-08-01", "2026-07-31", "2026-07-30"]),
                d("2026-08-01")
            )
            .streak,
            3
        );
        // a day file with no parseable records is not an active day
        let mut days = at(&["2026-07-27", "2026-07-25"]);
        days.push((d("2026-07-26"), Vec::new()));
        assert_eq!(compute(&days, today).streak, 1);
    }

    #[test]
    fn collect_reads_every_jsonl_day() {
        let dir = TempDir::new().unwrap();
        let mut cfg = ConfigStore::load(dir.path().join("config.ini"), dir.path());
        let vault = dir.path().join("vault");
        cfg.set("vault_dir", vault.to_str().unwrap());
        cfg.set("fallback_dir", dir.path().join("logs").to_str().unwrap());
        fs::create_dir_all(&vault).unwrap();
        let line = |text: &str, clean: &str, secs: f64| {
            serde_json::to_string(&rec(text, clean, secs)).unwrap() + "\n"
        };
        let today = Local::now().date_naive();
        let yesterday = today.checked_sub_days(Days::new(1)).unwrap();
        fs::write(
            vault.join(format!("{}.jsonl", today.format("%Y-%m-%d"))),
            line("one two", "One two.", 2.0) + "not json\n",
        )
        .unwrap();
        fs::write(
            vault.join(format!("{}.jsonl", yesterday.format("%Y-%m-%d"))),
            line("three four five six", "", 2.0),
        )
        .unwrap();
        // stray files are ignored by the day listing
        fs::write(
            vault.join("notes.jsonl"),
            line("ignored words here", "", 9.0),
        )
        .unwrap();
        let s = collect(&cfg);
        assert_eq!(s.takes, 2);
        assert_eq!(s.words, 6);
        assert_eq!(s.wpm, 90, "6 words over 4 s");
        assert_eq!(s.streak, 2);
        let v = s.to_json();
        assert_eq!(v["words"], 6);
        assert_eq!(v["streak"], 2);
        assert!(v["minutesSaved"].is_number());
    }
}
