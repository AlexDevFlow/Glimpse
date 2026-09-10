APP      = Glimpse
BUILD    = build
BUNDLE   = $(BUILD)/$(APP).app
CONTENTS = $(BUNDLE)/Contents
DEPLOY   = 15.0
LPROJ    = $(wildcard Resources/Localization/*.lproj)

# Releases are universal (Apple silicon + Intel); a plain `make bundle` builds only
# for this Mac, which halves the build time while developing. `--triple` is used
# instead of `--arch` because the latter needs a full Xcode install, and this
# project is meant to build with the Command Line Tools alone.
UNIVERSAL ?= 0
ifeq ($(UNIVERSAL),1)
  ARCHS = arm64 x86_64
else
  ARCHS = $(shell uname -m)
endif
BIN    = $(BUILD)/$(APP)-bin
SLICES = $(foreach a,$(ARCHS),.build/$(a)-apple-macosx/release/$(APP))

# Sign with the local "Glimpse Dev" identity when it exists (see
# scripts/make-signing-cert.sh), otherwise ad-hoc. A stable identity keeps the
# Screen Recording permission across rebuilds.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"Glimpse Dev"' && echo "Glimpse Dev" || echo "-")

.PHONY: all build bundle universal icon force-icon run install check test zip clean

all: bundle

build:
	@mkdir -p $(BUILD)
	@for arch in $(ARCHS); do \
		echo "swift build -c release --triple $$arch-apple-macosx$(DEPLOY)"; \
		swift build -c release --triple $$arch-apple-macosx$(DEPLOY) || exit 1; \
	done
	@lipo -create -output $(BIN) $(SLICES)
	@echo "Binary: $$(lipo -archs $(BIN))"

icon: Resources/AppIcon.icns

# The icon is committed and its rule is order-only, so `make icon` is a no-op once
# it exists. Use this after editing scripts/make-icon.swift.
force-icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

# Order-only: the icon is committed, so it is regenerated only when missing.
# A normal prerequisite would fire whenever a checkout happens to write the
# script a second later than the icon, and drive AppKit on a headless runner.
Resources/AppIcon.icns: | scripts/make-icon.swift
	swift scripts/make-icon.swift Resources/AppIcon.icns

# Every .lproj is copied verbatim; CFBundleLocalizations in Info.plist must list
# the same set, and `make check` verifies the keys line up.
bundle: build icon
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BIN) $(CONTENTS)/MacOS/$(APP)
	@# swift build records every source file by absolute path in the symbol table,
	@# so an unstripped release announces whoever built it. Before signing.
	strip -S $(CONTENTS)/MacOS/$(APP)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	cp -R $(LPROJ) $(CONTENTS)/Resources/
	codesign --force --options runtime --entitlements Resources/Glimpse.entitlements \
		--sign "$(SIGN_IDENTITY)" $(BUNDLE)
	@echo "Built $(BUNDLE)"

# What a release ships: both architectures in one bundle.
universal:
	$(MAKE) UNIVERSAL=1 bundle

run: bundle
	open $(BUNDLE)

install: bundle
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP).app"

# Every translation has the same keys and the same format placeholders as English.
# Runs with the Command Line Tools alone, so it is the check that always works.
check:
	swift scripts/check-localization.swift

# Unit tests for the pure logic (shortcut encoding, geometry, profiles, language
# list). swift-testing needs a full Xcode install to run; the app itself does not.
test:
	@# The runner's developer dir is Xcode_16.x.app, so match on what it is NOT.
	@[ "$$(xcode-select -p 2>/dev/null)" != "/Library/Developer/CommandLineTools" ] || { \
		echo "swift-testing needs a full Xcode install; the app itself does not."; \
		echo "Everything except this target works with the Command Line Tools."; \
		exit 1; }
	swift test

# Release archive. Ditto (not zip) so the bundle's signature survives.
zip: universal
	cd $(BUILD) && ditto -c -k --keepParent --sequesterRsrc $(APP).app $(APP)-macos.zip
	@echo "Wrote $(BUILD)/$(APP)-macos.zip"

clean:
	rm -rf $(BUILD) .build
