# Development

```bash
make test        # unit + integration suite
make eval        # calibration report
make icon        # regenerate the app icon and README images
make bundle      # assemble build/Hebrish.app
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

## Tests

XCTest is unavailable in a Command Line Tools-only toolchain, so the suite uses
swift-testing. `Testing.framework` ships with CLT but needs explicit search
paths, which the Makefile supplies.

Use `make test`, never bare `swift test`. On this toolchain
`swiftpm-testing-helper` aborts with signal 6 during process *teardown*, after
the tests have finished, so the exit code carries no information. Worse, the
abort races the summary line: about one run in five it wins and no summary is
printed, which made an earlier stdout-parsing gate report failures when nothing
had failed.

`scripts/run-tests.sh` therefore judges the run from swift-testing's JUnit XML,
which is written before teardown and states the counts outright. It prints them,
so a pass is legible rather than inferred:

```
==> 76 tests, 0 failures, 0 errors, 0 skipped
==> PASS
```

## Verifying in real apps

Injection behaviour is the one thing tests cannot cover. Checklist:

| App | Correction lands | Layout switches |
|---|---|---|
| TextEdit | | |
| Notes | | |
| Safari (text field) | | |
| Slack | | |
| VS Code | | |
| Terminal | | |

## Verifying the toast

`LayoutFixApp --demo-menu` prints the whole menu as a tree, including the
rejected-words submenu and the hidden identifier behind each row, which is
otherwise only checkable by opening the menu by hand. It runs against a scratch
preferences domain, never your own, so printing a diagnostic cannot disturb the
list it describes.

`LayoutFixApp --demo-toast` shows a sample panel for 20 seconds and prints what
matters about it: that the app stayed inactive, that the panel cannot become
key, its level, and the on-screen rect of the Undo button. Useful because the
panel is otherwise only reachable by provoking a real correction.

Note that synthesised clicks cannot exercise the button from a process without
Accessibility access — `CGEventPost` is silently dropped — so the click path has
to be checked by hand.

## Known limitations

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

## Sharing a build

**Building from source is the easy path**, and not for the usual reasons: a
locally built app carries no quarantine flag, so Gatekeeper never gets involved.
On the other Mac:

```bash
git clone https://github.com/raznis/hebrish.git && cd hebrish && make install
```

That fetches the language data, bakes the lexicon, builds, signs and installs in
one step. It needs only the Command Line Tools (`xcode-select --install`), not
Xcode. Then grant the two permissions above.

**If they would rather not build it**, `make dist` produces a universal
(Apple Silicon + Intel) `dist/Hebrish.zip`, about 2 MB. Send them that, and
they must clear the quarantine flag after downloading:

```bash
unzip Hebrish.zip -d /Applications/
xattr -dr com.apple.quarantine /Applications/Hebrish.app
open /Applications/Hebrish.app
```

The `xattr` step is not optional. Hebrish is ad-hoc signed, not signed with a
Developer ID and not notarized, so a downloaded copy is quarantined and macOS
will refuse to launch it — reporting it as damaged or from an unidentified
developer. Removing the flag is what lets it run. Distributing it without that
warning would just waste their time.

`make dist` writes only to `dist/` and deliberately never touches
`/Applications`: TCC binds each permission to the exact binary hash, so
overwriting an installed copy silently revokes a working grant.
