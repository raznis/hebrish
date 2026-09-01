# LayoutFix — build, test, bundle.
#
# Works with Command Line Tools only (no Xcode). XCTest is unavailable in a
# CLT-only toolchain, so the suite uses swift-testing; the framework ships with
# CLT but needs an explicit search path, which TESTFLAGS supplies.

APP_NAME    := LayoutFix
BUNDLE_ID   := com.raznissim.layoutfix
EXECUTABLE  := LayoutFixApp
CONFIG      ?= release

BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    := $(APP_BUNDLE)/Contents
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

.PHONY: all build debug test bundle sign run install uninstall lexicon data eval clean help

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

lexicon: data build
	$(BIN_PATH)/BakeLexicon \
	  --en data/en_50k.txt \
	  --he data/he_50k.txt \
	  --sys-words $(SYS_WORDS) \
	  --out Resources/lexicon.bin

# The harness builds its own lexicons (including held-out ones) from the raw
# lists, so it takes data/ rather than the baked blob.
eval: data build
	$(BIN_PATH)/LayoutFixEval --en data/en_50k.txt --he data/he_50k.txt \
	  --sys-words $(SYS_WORDS) $(EVAL_ARGS)

# --- app bundle --------------------------------------------------------------

bundle: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BIN_PATH)/$(EXECUTABLE) $(CONTENTS)/MacOS/$(EXECUTABLE)
	cp App/Info.plist $(CONTENTS)/Info.plist
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@if [ -f Resources/lexicon.bin ]; then \
	  cp Resources/lexicon.bin $(CONTENTS)/Resources/lexicon.bin; \
	  echo "bundled lexicon.bin"; \
	else \
	  echo "WARNING: Resources/lexicon.bin missing - run 'make lexicon' first"; \
	fi
	@$(MAKE) --no-print-directory sign
	@echo "built $(APP_BUNDLE)"

# Ad-hoc signature with a stable identifier. The identifier is what keeps the
# Accessibility grant attached to the app across rebuilds; the cdhash still
# changes, so macOS may re-prompt after a rebuild.
sign:
	codesign --force --sign - --identifier $(BUNDLE_ID) \
	  --options runtime --timestamp=none $(APP_BUNDLE) 2>&1 | grep -v '^$$' || true

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

clean:
	rm -rf .build $(BUILD_DIR)
