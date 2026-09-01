# LayoutFix

A macOS menu-bar agent that notices when you have typed a word in the wrong
keyboard layout — English text on a Hebrew input source, or Hebrew text on an
English one — rewrites it in place, and switches the input source for you.

Type `akuo kfo hksho uhksu,` with English active and you get
`שלום לכם ילדים וילדות`, with the input source flipped to Hebrew, so the rest
of the sentence lands correctly without you touching anything.

It works because QWERTY↔Hebrew is a fixed one-to-one mapping of *physical keys*,
so the gibberish is losslessly recoverable. The hard part is not the mapping —
it is deciding, fast and reliably, that a conversion is warranted at all.

## Install

Requires macOS 13+ and the Swift toolchain (Command Line Tools is enough — no
Xcode needed).

```bash
make lexicon && make install
```

Then open `/Applications/LayoutFix.app` and grant Accessibility access:
**System Settings → Privacy & Security → Accessibility → enable LayoutFix**.
A keyboard event tap cannot work without it. Quit and relaunch afterwards.

Turn on *Open at Login* from the menu-bar menu to have it start with the Mac.

`make lexicon` downloads two frequency lists (~1.4 MB) from
[hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords) and
bakes them, together with `/usr/share/dict/words`, into
`Resources/lexicon.bin`. Both lists are OpenSubtitles-derived and CC-BY-SA 4.0.

## Using it

There is no configuration to speak of. The menu bar shows **א** while active
and a struck-through **a** while paused, plus a count of corrections and the
last one made. *Diagnostics…* reports everything the app can see about its own
environment — the first place to look if it seems inert.

Two behaviours worth knowing:

- **It fires at a word boundary**, not mid-word. Usually that is the first word,
  so you never see the wrong text.
- **It repairs backwards.** If the first word was too short to judge — `מה`,
  `is` — a later word settles the question and the already-typed words are
  fixed in the same edit.

## How it decides

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

## Safety and privacy

This is a process that can see every keystroke, and it is built accordingly.

- **Nothing typed is ever written to disk.** The buffer is in-memory, bounded to
  64 keystrokes, and overwritten on reset. Typed text reaches the log only at
  `debug` level and marked `private`, so it is redacted by default.
- **Password fields are skipped entirely.** While `IsSecureEventInputEnabled()`
  is true no keystroke is examined, buffered, or acted on.
- **Password managers are excluded** by bundle ID out of the box (1Password,
  Bitwarden, LastPass, Keychain Access, the macOS security agent).
- **The tap is listen-only.** It cannot suppress a keystroke, so no bug here can
  swallow your typing. The cost is that a correction has to delete and retype
  the boundary character.
- **The buffer is discarded** on arrow keys, Home/End/PageUp/Down, Escape,
  backspace, any Cmd/Ctrl/Opt chord, Return, a mouse click, an app switch, a
  manual layout switch, and a 4-second pause — anything after which the text we
  think is on screen may not be. That last group also means lookback can never
  reach back across a language you switched into deliberately.

There is **no undo**. That was a deliberate choice, and it is why the false
alarm rate above is the number the calibration is built around. Adding a revert
hotkey is a small change: `Coordinator` already keeps the last `Correction`,
which carries everything needed to reverse it.

## Development

```bash
make test        # unit + integration suite
make eval        # calibration report
make bundle      # assemble build/LayoutFix.app
make run         # bundle, relaunch
make install     # copy to /Applications
```

`Sources/LayoutFixCore` holds all the judgement and has no AppKit dependency:
layout derivation, transliteration, the lexicon, the scorer, the typing buffer,
and the correction engine. `CorrectionEngine` is pure — it is told about key
events and returns what should happen — so the app layer only does I/O.

Layout tables are derived at runtime from the enabled input sources via
`UCKeyTranslate`, not hardcoded, so Hebrew-Standard, Hebrew-PC, Hebrew-QWERTY
and non-US Latin layouts all work with no extra code.

### Tests

XCTest is unavailable in a Command Line Tools-only toolchain, so the suite uses
swift-testing. `Testing.framework` ships with CLT but needs explicit search
paths, which the Makefile supplies. `swiftpm-testing-helper` also aborts during
process teardown *after* reporting, so `scripts/run-tests.sh` judges the run
from swift-testing's own summary rather than the exit code. Use `make test`, not
bare `swift test`.

### Verifying in real apps

Injection behaviour is the one thing tests cannot cover. Checklist:

| App | Correction lands | Layout switches |
|---|---|---|
| TextEdit | | |
| Notes | | |
| Safari (text field) | | |
| Slack | | |
| VS Code | | |
| Terminal | | |

### Known limitations

- **A rebuild changes the ad-hoc signature**, so macOS may ask you to re-grant
  Accessibility access after `make install`. Signing with a stable self-signed
  identity avoids this.
- **Injection fidelity varies by app.** Text is posted one character at a time
  as a Unicode string, which is what text expanders do and works nearly
  everywhere, but Electron apps and terminals are occasionally fussy about event
  timing. `interKeyDelayMilliseconds` in `UserDefaults` is the knob.
- **Typing during an injection can interleave.** A correction occupies roughly
  10–50 ms; a keystroke landing inside that window can corrupt the result. Only
  an active (suppressing) tap could close this fully.
- **Only two scripts.** If a third input source is live, the app stands down.
