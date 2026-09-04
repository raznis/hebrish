# LayoutFix — build, test, bundle.
#
# Works with Command Line Tools only (no Xcode). XCTest is unavailable in a
# CLT-only toolchain, so the suite uses swift-testing; the framework ships with
# CLT but needs an explicit search path, which TESTFLAGS supplies.

APP_NAME    := Hebrish
BUNDLE_ID   := com.raznissim.hebrish
# The name the bundle presents, via CFBundleExecutable. This is what shows up in
# Activity Monitor and what `pkill -x` matches.
EXECUTABLE  := Hebrish
# The SwiftPM product name, deliberately left alone: renaming the Swift targets
# would touch every file for no user-visible gain, since CFBundleExecutable lets
# the bundle present a clean name regardless.
BIN_NAME    := LayoutFixApp
CONFIG      ?= release

BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    := $(APP_BUNDLE)/Contents
DIST_DIR    := dist
DIST_APP    := $(DIST_DIR)/$(APP_NAME).app
DIST_CONTENTS := $(DIST_APP)/Contents
BIN_PATH    := $(shell swift build -c $(CONFIG) --show-bin-path)

DEVDIR      := $(shell xcode-select -p)
TESTFW      := $(DEVDIR)/Library/Developer/Frameworks
TESTLIB     := $(DEVDIR)/Library/Developer/usr/lib
TESTFLAGS   := $(if $(wildcard $(TESTFW)/Testing.framework),\
                 -Xswiftc -F$(TESTFW) -Xlinker -F -Xlinker $(TESTFW) \
                 -Xlinker -rpath -Xlinker $(TESTFW) \
                 -Xlinker -rpath -Xlinker $(TESTLIB),)

FREQ_BASE   := https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018
SYS_WORDS   := /usr/share/dict/words

.PHONY: all build debug test bundle sign run install uninstall lexicon data eval dist clean help

all: bundle

help:
	@echo "make build     - release build of all targets"
	@echo "make test      - run the unit suite"
	@echo "make data      - download the EN/HE frequency lists into data/"
	@echo "make lexicon   - bake data/ + $(SYS_WORDS) into Resources/lexicon.bin"
	@echo "make eval      - threshold calibration report (needs lexicon)"
	@echo "make bundle    - assemble $(APP_BUNDLE)"
	@echo "make run       - bundle, then relaunch the agent"
	@echo "make install   - copy the app into /Applications"
	@echo "make dist      - universal .app + zip in dist/, for another Mac"

build:
	swift build -c $(CONFIG)

debug:
	swift build

test:
	@./scripts/run-tests.sh $(TESTFLAGS)

# --- language data -----------------------------------------------------------

data: data/en_50k.txt data/he_50k.txt

data/en_50k.txt:
	@mkdir -p data
	curl -fsSL "$(FREQ_BASE)/en/en_50k.txt" -o $@
	@echo "fetched $@ ($$(wc -l < $@) lines)"

data/he_50k.txt:
	@mkdir -p data
	curl -fsSL "$(FREQ_BASE)/he/he_50k.txt" -o $@
	@echo "fetched $@ ($$(wc -l < $@) lines)"

lexicon: Resources/lexicon.bin

Resources/lexicon.bin: data build
	$(BIN_PATH)/BakeLexicon \
	  --en data/en_50k.txt \
	  --he data/he_50k.txt \
	  --sys-words $(SYS_WORDS) \
	  --out $@

# The harness builds its own lexicons (including held-out ones) from the raw
# lists, so it takes data/ rather than the baked blob.
eval: data build
	$(BIN_PATH)/LayoutFixEval --en data/en_50k.txt --he data/he_50k.txt \
	  --sys-words $(SYS_WORDS) $(EVAL_ARGS)

# --- app bundle --------------------------------------------------------------

bundle: build Resources/lexicon.bin
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BIN_PATH)/$(BIN_NAME) $(CONTENTS)/MacOS/$(EXECUTABLE)
	cp App/Info.plist $(CONTENTS)/Info.plist
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	cp Resources/lexicon.bin $(CONTENTS)/Resources/lexicon.bin
	@$(MAKE) --no-print-directory sign
	@echo "built $(APP_BUNDLE)"

# Ad-hoc signature with a stable identifier.
#
# Deliberately WITHOUT --options runtime. The hardened runtime is for notarized
# Developer ID builds; on an ad-hoc binary carrying no entitlements macOS
# applies its strict prompting policy and refuses to register the app for TCC at
# all -- tccd logs "DB Action:None" for Input Monitoring (so the app never
# appears in the list) and auto-denies Accessibility as "(System Set)". The user
# is then stuck: no prompt, no list entry, nothing to switch on.
sign:
	codesign --force --sign - --identifier $(BUNDLE_ID) \
	  --timestamp=none $(APP_BUNDLE) 2>&1 | grep -v '^$$' || true

run: bundle
	-@pkill -x $(EXECUTABLE) 2>/dev/null || true
	@sleep 0.3
	open $(APP_BUNDLE)
	@echo "launched. look for the menu-bar item."

install: bundle
	@rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_BUNDLE) /Applications/
	@echo "installed to /Applications/$(APP_NAME).app"

uninstall:
	-@pkill -x $(EXECUTABLE) 2>/dev/null || true
	rm -rf /Applications/$(APP_NAME).app

# --- distributable for another Mac -------------------------------------------

# A universal build, so it runs on both Apple Silicon and Intel.
#
# SwiftPM's own --arch flag needs full Xcode (it shells out to xcbuild), so
# build each slice separately and lipo them. Output goes to dist/ and never
# touches the installed copy: TCC binds each permission to the exact binary
# hash, so overwriting /Applications would silently revoke a working grant.
dist: Resources/lexicon.bin
	@rm -rf $(DIST_DIR)
	@mkdir -p $(DIST_CONTENTS)/MacOS $(DIST_CONTENTS)/Resources
	swift build -c release --triple arm64-apple-macosx13.0
	swift build -c release --triple x86_64-apple-macosx13.0
	lipo -create -output $(DIST_CONTENTS)/MacOS/$(EXECUTABLE) \
	  .build/arm64-apple-macosx/release/$(BIN_NAME) \
	  .build/x86_64-apple-macosx/release/$(BIN_NAME)
	cp App/Info.plist $(DIST_CONTENTS)/Info.plist
	@printf 'APPL????' > $(DIST_CONTENTS)/PkgInfo
	cp Resources/lexicon.bin $(DIST_CONTENTS)/Resources/lexicon.bin
	codesign --force --sign - --identifier $(BUNDLE_ID) \
	  --timestamp=none $(DIST_APP) 2>&1 | grep -v '^$$' || true
	cd $(DIST_DIR) && zip -qry $(APP_NAME).zip $(APP_NAME).app
	@echo
	@echo "built $(DIST_DIR)/$(APP_NAME).zip  ($$(du -h $(DIST_DIR)/$(APP_NAME).zip | cut -f1))"
	@echo "  architectures: $$(lipo -archs $(DIST_CONTENTS)/MacOS/$(EXECUTABLE))"
	@echo
	@echo "The recipient must clear Gatekeeper's quarantine after downloading:"
	@echo "  xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app"

clean:
	rm -rf .build $(BUILD_DIR) $(DIST_DIR)
