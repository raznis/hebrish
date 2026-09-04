# How Hebrish decides

Hebrish works because QWERTY↔Hebrew is a fixed one-to-one mapping of *physical
keys*, so mis-keyed text is losslessly recoverable. That part is easy. The hard
part — and what this document is about — is deciding, fast and reliably, that a
conversion is warranted at all.

## The decision

For each token the app keeps the *keycodes*, not the characters, so both the
Latin and the Hebrew reading are always available regardless of which layout was
live. It then compares them as a log-likelihood ratio. Both readings come from
the same number of key presses, so their lengths match and the ratio is a fair
comparison rather than a length artefact.

Each reading is scored as a mixture of:

- **Unigram frequency** from the 50k lists, plus `/usr/share/dict/words` merged
  into the English vocabulary as membership-only at a floor probability. That
  asymmetry is deliberate: rare, technical and proper-noun English is exactly
  what must not be mangled, so the floor biases errors toward *missing* a
  correction rather than making a wrong one.
- **A character trigram model** with stupid-backoff, trained on the same corpora
  weighted by real frequency, which handles inflections and names the vocabulary
  has never seen. The dictionary floor words are kept *out* of this model — 200k
  archaic headwords would drag the spelling model away from the language people
  actually type.
- **Hebrew particle stripping** (ו/ה/ב/ל/כ/מ/ש), because a 50k vocabulary misses
  many inflected forms.
- **Orthographic vetoes.** A Hebrew final form (ך ם ן ף ץ) in non-final position
  is impossible, and it is the single strongest signal available — `hello` typed
  on a Hebrew layout is `יקךךם`, with a final-kaf in the middle. Vowelless Latin
  is near-enough impossible too.

The margin required **scales with token length**. Two letters of agreement is
coincidence where six is proof, so short tokens must clear a much larger bar.
This cut false positives tenfold versus a flat threshold while keeping
long-token recall — and it beats a hard minimum length, which would have gutted
recall on Hebrew's many short words.

Once a token does fire, earlier words in the same run are re-examined under a
relaxed rule, since the context is now established. Vocabulary membership stays
mandatory there as the anchor that stops a loose threshold inventing words. That
change took prefix recovery from 19.5% to 99%.

### Measured behaviour

`make eval` builds the lexicons, fires a synthetic wrong-layout corpus through
the real decision code, and reports the tradeoff. It replays
`Scorer.shouldConvert` rather than reimplementing it, so its numbers cannot
drift from what the app actually does.

At the calibrated threshold (τ = 6 nats, which the harness picks on its own):

| | |
|---|---|
| False alarms on correctly typed text | **0** in 48,000 words |
| Single-token false positives | 3 in 40,000 |
| Hebrew-on-English caught by word 1 | **72.5%** |
| …by word 2 | 92.6% |
| …by word 6 | 100.0% |
| English-on-Hebrew caught by word 1 | 66.2% |
| …by word 2 | 88.6% |
| Already-typed words repaired by lookback | 99.0% / 99.7% |

Sentences are sampled frequency-weighted, so they have the same
short-common-word problem real typing does.

The harness also reports an out-of-vocabulary section, where a slice of each
vocabulary is withheld from both the word list and the character model. Recall
there is much lower by design — an unknown word cannot be confirmed as a word —
which is the conservative direction.

## Privacy

This is a process that can see every keystroke, and it is built accordingly.

- **One thing typed is stored, and only one.** When you undo a correction,
  the word you rejected is saved so it is never corrected again. That list is
  the *only* durable trace Hebrish keeps of anything typed: it holds only
  words you actively rejected, is capped at 500 entries, and is fully visible
  and editable from the menu — remove any single word, or forget all of them.
- **Nothing else typed is written to disk.** The buffer is in-memory, bounded to
  64 keystrokes, and overwritten on reset. Typed text reaches the log only at
  `debug` level and marked `private`, so it is redacted by default and not
  persisted to the on-disk log store.
- **Password fields are skipped, by two independent checks.** While
  `IsSecureEventInputEnabled()` is true, no keystroke is examined, buffered or
  acted on. That flag alone is not enough, though: it only goes true when an app
  explicitly calls `EnableSecureEventInput()`, which native `NSSecureTextField`
  does — the login window, System Settings, Keychain Access — while web password
  fields and most Electron apps do not. So Hebrish also asks Accessibility
  what kind of field has focus and stands down on any secure text field.

  It reads the field's *role*, never its value. Hebrish has no business
  knowing what is in a field, only what kind of field it is.

  The honest limit: the second check works only where an app exposes the secure
  subrole, and if the query fails Hebrish carries on as it would have anyway.
  It closes most of the gap; it is not a guarantee. Which apps report what is
  recorded in the log, one line per app and field kind.
- **Password managers are excluded** by bundle ID out of the box (1Password,
  Bitwarden, LastPass, Keychain Access, the macOS security agent).
- **The tap is listen-only.** It cannot suppress a keystroke, so no bug here can
  swallow your typing. The cost is that a correction has to delete and retype
  the boundary character.
- **Field kinds are logged, once each.** The first time a distinct
  app-and-field-kind combination is seen, it is recorded at `info` level as e.g.
  `com.apple.Safari AXTextField/AXSecureTextField [SECURE - standing down]`.
  Structural identifiers and the bundle id only — never field contents, and
  never the field's label, which can itself be revealing. This is how the
  remaining password-field coverage gets measured against real apps:

  ```bash
  log show --last 1h --info --predicate 'subsystem == "com.raznissim.hebrish"' | grep "field kind"
  ```
- **The buffer is discarded** on arrow keys, Home/End/PageUp/Down, Escape,
  backspace, any Cmd/Ctrl/Opt chord, Return, a mouse click, an app switch, a
  manual layout switch, and a 4-second pause — anything after which the text we
  think is on screen may not be. That last group also means lookback can never
  reach back across a language you switched into deliberately.

Undo is deliberately conservative. A correction stays reversible while we can
still be certain where its text is: you may keep typing, and undo reaches back
over what you added, but arrow keys, backspace, a command chord, a click
elsewhere, an app switch or a layout change all give it up rather than risk
deleting the wrong characters. A wrong undo would be worse than no undo.
