# Flow features — shared spec for desktop (Rust) and iOS (Swift)

Tiro's desktop app and the iOS app implement the same feature set, modeled on
Wispr Flow, but 100% on device, free, with no accounts and no telemetry. This
file is the contract both implementations follow. `format_cases.json` next to
it holds the test vectors; both test suites load it, so the two formatters can
never drift apart.

## Feature set

| Feature | Desktop | iOS |
|---|---|---|
| Dictate anywhere | Global hotkeys (existing) | Tiro keyboard: mic key in any app |
| Local transcription | whisper.cpp, GGUF models (existing) | whisper.cpp xcframework, same GGUF models |
| Smart formatting | `format::format_text` | `SmartFormatter.format` |
| Spoken commands ("new line", "comma", "scratch that") | yes | yes |
| Writing styles: formal / casual / very casual | yes | yes |
| Dictionary: hot words + corrections | existing (`vocab.txt`, `corrections.txt`) | same two lists |
| Snippets: say a cue phrase, get saved text | new (`snippets.txt`) | yes |
| Languages: English or any Whisper language, or auto-detect | new `language` key | yes |
| History with search, copy, delete | existing (Transcribe page) | yes |
| Stats: words, takes, WPM, time saved, streak | new | yes |
| Models: download / delete / choose | existing | yes |
| Verbatim always logged, cleanup only touches the delivered copy | existing | yes |

## The formatting pipeline

`format(verbatim, options) -> String`

Options:

| Option | Values | Default | Config key (desktop) |
|---|---|---|---|
| `cleanup` | `none` \| `light` \| `fillers` | `light` | `clipboard_cleanup` |
| `spoken_commands` | bool | `true` | `spoken_commands` |
| `style` | `formal` \| `casual` \| `very_casual` | `formal` | `style` |
| `corrections` | list of `(heard, written)` | `[]` | `corrections.txt` |
| `snippets` | list of `(trigger, expansion)` | `[]` | `snippets.txt` |

Steps, in this exact order:

1. **Whitespace.** Collapse all runs of whitespace to one space and trim. If
   the result is empty, return `""`.
2. **Whole-take snippet.** Normalize the take: lowercase, remove every
   character that is not a letter, digit or space, collapse spaces, trim. If it
   equals a snippet trigger normalized the same way, return that snippet's
   expansion exactly as saved (no other step runs). First matching snippet in
   list order wins.
3. **`cleanup == none`:** skip to step 9 (corrections), then step 10
   (snippets), then return.
4. **Spoken commands** (only when `spoken_commands`). All matches are
   case-insensitive and on whole words (`\b` on both sides; inner spaces of a
   two-word command match one or more spaces). Three passes, in this order:
   1. *Line breaks.* `new paragraph` → `\n\n`, then `new line` → `\n`. The
      match also swallows the spaces before the command and any `,.;:!?` plus
      spaces right after it. Punctuation before it is kept
      ("Dear team, new paragraph. Thanks" → "Dear team,\n\nThanks").
   2. *Punctuation.* `question mark` → `?`; `exclamation point` and
      `exclamation mark` → `!`; `full stop` → `.`; `semicolon` → `;`;
      `colon` → `:`; `comma` → `,`; `period` → `.`, except when the word right
      before it (ignoring punctuation and spaces) is one of `a an the this that
      each every any some which what trial grace waiting cooling probation
      billing` — then it is the ordinary word and stays. The match swallows
      any spaces and `,.;:!?` on both sides, and the mark is emitted followed
      by one space ("Hello, comma, how" → "Hello, how").
   3. *Deletion.* `scratch that`, `delete that`, `strike that`: take the first
      one in the text. Its match swallows any `,.;:!?` plus spaces right after
      it. Delete from just after the nearest `.`, `!`, `?` or newline before
      the command (or from the start of the text) through the end of the
      match, and put one space in its place. Repeat until none are left.
   After the three passes: collapse runs of spaces/tabs to one space, remove
   spaces/tabs before `,.;:!?`, trim spaces at the start and end of every line,
   replace three or more newlines in a row with two, and trim the whole text.
   If that leaves the text empty (the take was only "scratch that"), return
   `""`.
5. **Fillers** (only when `cleanup == fillers`). Remove
   `\b(um+|uh+|erm+|hmm+)\b,?[ \t]*` case-insensitively (spaces and tabs
   only, never newlines), collapse runs of spaces/tabs to one space, and trim
   every line and the whole text. If the text is now empty, go to step 9 with
   the step-1 text (an all-filler take is delivered as said, never lost).
6. **Light rules** (whenever `cleanup != none`):
   - remove spaces/tabs before `,.!?;:`;
   - standalone lowercase `i` → `I` (covers i'm, i'll, i've, i'd);
   - uppercase the first character of the text and of every line;
   - if the text does not end with `.`, `!` or `?`, append `.`.
7. **Style.**
   - `formal`: nothing more.
   - `casual`: if the text ends with `.` but not `..`, drop that last `.`.
   - `very_casual`: `casual`, then at every sentence start (the text start,
     every line start, and the first letter after `. `, `! ` or `? `), take
     the word there (letters and apostrophes). If the word is not `I` and does
     not start with `I'`, and every letter after its first is lowercase,
     lowercase its first letter. "Hello" → "hello", "A" → "a", "NASA" and
     "I'm" stay.
8. (reserved; the empty-take guards live in steps 4 and 5)
9. **Corrections.** The existing desktop rule: each `heard => written` pair,
   in order, is a case-insensitive literal match with `\b` only on the sides of
   `heard` that start or end with a word character; `written` is inserted
   literally. If the result is blank, keep the text from before this step.
10. **Inline snippets.** Same matching rule as corrections, applied for each
    `trigger => expansion` pair in order, inserting the expansion literally.

The verbatim transcript (the step-0 input) is what gets logged; the output of
this pipeline is only what is delivered (clipboard, paste, keyboard insert).
Both are stored in the transcript record (`text` and `clean`).

## Storage formats

- **Transcripts**: unchanged from desktop. One JSONL and one Markdown file per
  day (`YYYY-MM-DD.jsonl`, `YYYY-MM-DD.md`). JSONL record fields:
  `ts` (`YYYY-MM-DDTHH:MM:SS` local), `text` (verbatim), `clean` (delivered),
  `mic`, `model`, `device` (`cpu`/`gpu`), `secs` (2 decimals).
- **Hot words**: `vocab.txt`, one per line, `#` comments.
- **Corrections**: `corrections.txt`, `heard => written` per line.
- **Snippets**: `snippets.txt`. One snippet per entry, `trigger => expansion`.
  An expansion may span lines: newlines inside an expansion are written as the
  two characters `\n`, and a literal backslash as `\\`. `#` comment lines and
  blank lines are ignored.

## Stats

Computed from the transcript records:
- **words**: count of whitespace-separated tokens in `clean` (or `text` when
  `clean` is empty), summed.
- **takes**: number of records.
- **WPM**: total words ÷ total `secs` × 60, rounded to an integer (0 when no
  seconds).
- **time saved**: words ÷ 40 WPM typing speed, minus total `secs`, floored at
  0, shown in minutes.
- **streak**: consecutive days, ending today or yesterday, that have at least
  one record.

## Initial prompt

Whisper's initial prompt is built from two optional parts, joined by one
space:
1. when `use_vocab_bias` is on and there are hot words: the hot words joined
   with spaces (whitespace collapsed), followed by `.`;
2. when `spoken_commands` is on and `cleanup != none`: the fixed primer
   `Comma, period, question mark, new line, new paragraph, scratch that.`

No parts → no prompt. Without the primer Whisper often writes the spoken word
"comma" as a name ("Kama"), so the command never fires; with it, the commands
come through as words the formatter can match (measured on base.en).

## Languages

`language` = `en` (default), `auto`, or a Whisper language code (`es`, `de`,
`fr`, …). English-only models (`*.en`) always run with `en`. For `auto`, call
whisper with language `auto` / `detect_language = false` (whisper picks the
language per take).
