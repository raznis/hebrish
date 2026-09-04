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

Then open `/Applications/LayoutFix.app` and grant it **two** permissions, which
live in two different lists under **System Settings → Privacy & Security**:

| Grant | Why |
|---|---|
| **Input Monitoring** | to notice a word typed in the wrong layout |
| **Accessibility** | to replace it |

Enable LayoutFix in both, then quit and relaunch it.

These are genuinely separate, and the failure mode is quiet: without Input
Monitoring, `CGEvent.tapCreate` still returns a valid tap and simply delivers
nothing — so an app can look like it is running while being completely deaf.
The menu's **Keys seen** counter is the honest check; it stays at 0 until Input
Monitoring is granted. *Diagnostics…* reports both grants.

### If the app never appears in the lists at all

A different failure from the one below, with a different cause: if LayoutFix is
missing from Input Monitoring entirely — no entry to switch on, no prompt — the
app was signed with the **hardened runtime**. That is for notarized Developer ID
builds; on an ad-hoc binary carrying no entitlements macOS applies its strict
prompting policy and declines to register the app for TCC at all. `tccd` logs
it plainly:

```
kTCCServiceListenEvent ... ReqResult(... DB Action:None ...)
Update Access Record: kTCCServiceAccessibility ... to Denied (System Set)
```

`make` does not pass `--options runtime` for exactly this reason. If you add it
back, this is the symptom.

### If it stays deaf

The menu's **Keys seen** counter is the ground truth. If it sits at 0 even
though both switches look enabled, the grant is stale: LayoutFix is ad-hoc
signed, so macOS binds each permission to the binary's *hash*, and any rebuild
silently invalidates it while leaving the switch showing on. Two copies of the
bundle at different paths produce two entries and the same confusion.

Clear it and start over:

```bash
pkill -x LayoutFixApp
tccutil reset ListenEvent com.raznissim.layoutfix
tccutil reset Accessibility com.raznissim.layoutfix
open /Applications/LayoutFix.app
```

Then grant both again. Keep exactly one copy of the app — if you have built it
locally, `rm -rf build/LayoutFix.app` after installing.

Turn on *Open at Login* from the menu-bar menu to have it start with the Mac.

`make lexicon` downloads two frequency lists (~1.4 MB) from
[hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords) and
bakes them, together with `/usr/share/dict/words`, into
`Resources/lexicon.bin`. Both lists are OpenSubtitles-derived and CC-BY-SA 4.0.

## Sharing it with another Mac

**Building from source is the easy path**, and not for the usual reasons: a
locally built app carries no quarantine flag, so Gatekeeper never gets involved.
On the other Mac:

```bash
git clone https://github.com/raznis/layoutfix.git && cd layoutfix && make install
```

That fetches the language data, bakes the lexicon, builds, signs and installs in
one step. It needs only the Command Line Tools (`xcode-select --install`), not
Xcode. Then grant the two permissions above.

**If they would rather not build it**, `make dist` produces a universal
(Apple Silicon + Intel) `dist/LayoutFix.zip`, about 2 MB. Send them that, and
they must clear the quarantine flag after downloading:

```bash
unzip LayoutFix.zip -d /Applications/
xattr -dr com.apple.quarantine /Applications/LayoutFix.app
open /Applications/LayoutFix.app
```

The `xattr` step is not optional. LayoutFix is ad-hoc signed, not signed with a
Developer ID and not notarized, so a downloaded copy is quarantined and macOS
will refuse to launch it — reporting it as damaged or from an unidentified
developer. Removing the flag is what lets it run. Distributing it without that
warning would just waste their time.

`make dist` writes only to `dist/` and deliberately never touches
`/Applications`: TCC binds each permission to the exact binary hash, so
overwriting an installed copy silently revokes a working grant.

## Using it

There is no configuration to speak of. The menu bar shows **א** while active
and a struck-through **a** while paused or lacking permission, plus how many
key events it has seen, a count of corrections, and the last one made.
*Diagnostics…* reports everything the app can see about its own environment —
the first place to look if it seems inert.

Two behaviours worth knowing:

- **It fires at a word boundary**, not mid-word. Usually that is the first word,
  so you never see the wrong text.
- **It repairs backwards.** If the first word was too short to judge — `מה`,
  `is` — a later word settles the question and the already-typed words are
  fixed in the same edit.
- **Every correction is shown, and offers Undo.** A small panel appears at the
  bottom of the screen with what changed and an **Undo** button (or press
  **⌘⌥Z**). It never takes keyboard focus, so clicking Undo does not disturb
  what you were typing.
- **Undo teaches it.** Rejecting a correction records that word permanently, so
  the same word is never converted again — including via the lookback path. The
  menu lists what has been rejected and can forget it all.

The panel is worth keeping on: a correction you do not notice is one you cannot
judge. Turn it off from the menu if you would rather not see it.

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

- **One thing typed is stored, and only one.** When you undo a correction,
  the word you rejected is saved so it is never corrected again. That list is
  the *only* durable trace LayoutFix keeps of anything typed: it holds only
  words you actively rejected, is capped at 500 entries, is listed in the menu,
  and *Forget Rejected Words…* clears it.
- **Nothing else typed is written to disk.** The buffer is in-memory, bounded to
  64 keystrokes, and overwritten on reset. Typed text reaches the log only at
  `debug` level and marked `private`, so it is redacted by default and not
  persisted to the on-disk log store.
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

Undo is deliberately conservative. A correction stays reversible while we can
still be certain where its text is: you may keep typing, and undo reaches back
over what you added, but arrow keys, backspace, a command chord, a click
elsewhere, an app switch or a layout change all give it up rather than risk
deleting the wrong characters. A wrong undo would be worse than no undo.

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

### Verifying the toast

`LayoutFixApp --demo-toast` shows a sample panel for 20 seconds and prints what
matters about it: that the app stayed inactive, that the panel cannot become
key, its level, and the on-screen rect of the Undo button. Useful because the
panel is otherwise only reachable by provoking a real correction.

Note that synthesised clicks cannot exercise the button from a process without
Accessibility access — `CGEventPost` is silently dropped — so the click path has
to be checked by hand.

### Known limitations

- **A rebuild changes the ad-hoc signature**, so macOS may ask you to re-grant
  both permissions after `make install`. Removing and re-adding the entry in
  the list clears a stale grant. Signing with a stable self-signed identity
  avoids the problem.
- **Injection fidelity varies by app.** Text is posted one character at a time
  as a Unicode string, which is what text expanders do and works nearly
  everywhere, but Electron apps and terminals are occasionally fussy about event
  timing. `interKeyDelayMilliseconds` in `UserDefaults` is the knob.
- **Typing during an injection can interleave.** A correction occupies roughly
  10–50 ms; a keystroke landing inside that window can corrupt the result. Only
  an active (suppressing) tap could close this fully.
- **Only two scripts.** If a third input source is live, the app stands down.
