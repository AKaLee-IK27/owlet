# Owlet — convenience targets. See CLAUDE.md for the underlying commands.

OWLET_DIR := Owlet
PROJECT   := $(OWLET_DIR)/Owlet.xcodeproj
SCHEME    := Owlet
CONFIG    := Debug
DERIVED   := /tmp/owlet-build
APP       := $(DERIVED)/Build/Products/$(CONFIG)/Owlet.app

.PHONY: help build run clean install verify

help: ## Show available targets
	@awk -F':.*##' '/^[a-zA-Z_-]+:.*##/ { printf "  make %-10s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: $(PROJECT) ## Debug build of the macOS app
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	    -configuration $(CONFIG) -destination 'platform=macOS' \
	    -derivedDataPath $(DERIVED) build

$(PROJECT): $(OWLET_DIR)/project.yml
	cd $(OWLET_DIR) && xcodegen generate

run: build ## Build, then open Owlet.app
	open $(APP)

clean: ## Remove build artifacts and generated Xcode project
	rm -rf $(DERIVED) $(PROJECT)

install: ## Sign + copy to ~/Applications (delegates to install.sh)
	./install.sh

verify: ## Full verification suite (delegates to init.sh)
	./init.sh
