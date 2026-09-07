# QuotaBar — menu bar quota monitor for Claude Code + Codex
APP_NAME   := QuotaBar
BUNDLE_ID  := com.gcdm.quotabar
BUILD_DIR  := .build/release
APP_DIR    := build/$(APP_NAME).app
# Signing identity. Order of precedence:
#   1. SIGN_ID on the command line            make SIGN_ID=<sha1> install
#   2. local.mk (untracked, per machine)      SIGN_ID := <sha1>
#   3. first valid "Apple Development" identity in the login keychain
#   4. ad-hoc ("-") when no identity exists
# A stable identity matters: the Keychain "Always Allow" for Claude Code's token is bound to it,
# and an ad-hoc signature changes on every build, so the prompt would return after each rebuild.
-include local.mk
SIGN_ID    ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | grep -v CSSMERR | head -1 | awk '{print $$2}')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID    := -
endif

.PHONY: build bundle run stop install clean

build:
	swift build -c release

bundle: build
	@echo "signing identity: $(SIGN_ID)"
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(APP_DIR)/Contents/Resources/AppIcon.icns
	@cp -R $(BUILD_DIR)/QuotaBar_QuotaBar.bundle $(APP_DIR)/Contents/Resources/
	@codesign --force --sign $(SIGN_ID) --identifier $(BUNDLE_ID) $(APP_DIR)
	@codesign --verify --strict $(APP_DIR) && echo "bundled + signed: $(APP_DIR)"

run: stop bundle
	open $(APP_DIR)

stop:
	@pkill -x $(APP_NAME) 2>/dev/null || true

install: stop bundle
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R $(APP_DIR) /Applications/
	open "/Applications/$(APP_NAME).app"

clean:
	rm -rf .build build
