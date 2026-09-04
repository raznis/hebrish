# Troubleshooting

Almost every problem with Hebrish is a permission problem, and macOS is
unhelpful about every one of them. Each section names a symptom.

The menu's **Keys seen** counter is the ground truth: if it climbs as you
type, Hebrish can read the keyboard, whatever System Settings shows.

## If the identifier will not resolve

`tccutil reset ... com.raznissim.hebrish` failing with

```
No such bundle identifier: OSStatus error -10814
```

means LaunchServices has not registered the bundle — typical right after copying
it into `/Applications`, and also why a freshly installed copy can show a
generic icon in Spotlight and Finder. Register it and reindex:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Hebrish.app
mdimport /Applications/Hebrish.app
```

Note the ordering trap: reset TCC *before* deleting an app. Once the bundle is
gone the identifier cannot be resolved, and its entries are stranded in the
Privacy & Security lists — removable only with the **−** button there.

## If the app never appears in the lists at all

A different failure from the one below, with a different cause: if Hebrish is
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

## If it is missing from Input Monitoring but present in Accessibility

An app appears in these lists only once macOS has written a TCC record for it,
and the Input Monitoring record is easy to lose: the prompt is asynchronous, and
anything that blocks the main thread while it is up can swallow it. `tccd` then
logs

```
Notifying for access kTCCServiceListenEvent ...
... ReqResult(... DB Action:None ...)
```

which is a prompt shown and no record written — so there is nothing in the list
to switch on. Accessibility is unaffected because a separate system agent drives
its prompt.

The fix does not need the record: in **Input Monitoring**, click **+** and choose
`/Applications/Hebrish.app`. That creates the entry directly.

(Hebrish no longer puts its own alert up straight after requesting, which was
the cause of this. Guidance now waits 12 seconds and appears only if the system
prompts went unanswered.)

## If it stays deaf

The menu's **Keys seen** counter is the ground truth. If it sits at 0 even
though both switches look enabled, the grant is stale: Hebrish is ad-hoc
signed, so macOS binds each permission to the binary's *hash*, and any rebuild
silently invalidates it while leaving the switch showing on. Two copies of the
bundle at different paths produce two entries and the same confusion.

Clear it and start over:

```bash
pkill -x LayoutFixApp
tccutil reset ListenEvent com.raznissim.hebrish
tccutil reset Accessibility com.raznissim.hebrish
open /Applications/Hebrish.app
```

Then grant both again. Keep exactly one copy of the app — if you have built it
locally, `rm -rf build/Hebrish.app` after installing.

Turn on *Open at Login* from the menu-bar menu to have it start with the Mac.

`make lexicon` downloads two frequency lists (~1.4 MB) from
[hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords) and
bakes them, together with `/usr/share/dict/words`, into
`Resources/lexicon.bin`. Both lists are OpenSubtitles-derived and CC-BY-SA 4.0.
