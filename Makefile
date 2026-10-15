# The xcconfig's MARKETING_VERSION is the single source of truth for the release
# version: vrsn bumps it, prepare-release tags it, and the release workflow
# stamps the tag back into it at build time. It must stay valid semver (X.Y.Z) —
# vrsn cannot parse a two-component version like 1.0.
VERSION_FILE = config/ClaudeSquad.xcconfig
VERSION_KEY = MARKETING_VERSION

.PHONY: help init arkana xcode build test screenshots clean patch minor major deploy

# `make` on its own prints this list rather than running the first target, which
# would otherwise be `init` — a target that installs Homebrew.
.DEFAULT_GOAL := help

help: ## Show this help
	@echo "claude-squad — available make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'


# MARK: - Dev tooling

init: ## Install Homebrew, brew/bundle dependencies, and the pinned Ruby
	which brew || /bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	brew bundle
	rbenv install --skip-existing
	rbenv exec gem install bundler
	rbenv exec bundle install

arkana: ## Regenerate the ArkanaKeys package from .env
	rbenv exec bundle exec arkana

xcode: ## Regenerate the Xcode project and open it
	make arkana
	git submodule update --init --recursive
	xcodegen
	open ClaudeSquad.xcodeproj

build: ## Build the Debug configuration
	set -o pipefail && xcodebuild -project ClaudeSquad.xcodeproj -scheme ClaudeSquad -configuration Debug build | xcbeautify

test: ## Run the unit and UI tests
	set -o pipefail && xcodebuild -project ClaudeSquad.xcodeproj -scheme ClaudeSquad -configuration Debug test | xcbeautify

screenshots: ## Regenerate the marketing screenshots in docs/
	./scripts/take-screenshots.sh

clean: ## Delete all Xcode DerivedData
	rm -rf ~/Library/Developer/Xcode/DerivedData


# MARK: - Releasing

# Bump the version, then tag + push. The release workflow picks up the tag,
# builds, signs with the Developer ID cert from the match repo, notarizes,
# uploads the zip to armcknight/homebrew-tools as a release asset, and bumps
# Casks/claude-squad.rb there.
#
# Requires `vrsn` and `prepare-release` on PATH (from the armcknight/tools cask).
#
# There is no deploy-beta target: this app has no `-rc` cask in the tap, and
# release.yml's tag filter matches only X.Y.Z, so an RC tag would do nothing.

patch: ## Bump the patch version (x.y.Z) and commit
	vrsn patch -f $(VERSION_FILE) -k $(VERSION_KEY) --commit

minor: ## Bump the minor version (x.Y.0) and commit
	vrsn minor -f $(VERSION_FILE) -k $(VERSION_KEY) --commit

major: ## Bump the major version (X.0.0) and commit
	vrsn major -f $(VERSION_FILE) -k $(VERSION_KEY) --commit

deploy: ## Migrate the changelog, tag the current version, and push (starts the release)
	@{ \
	prepare-release --file $(VERSION_FILE) --key $(VERSION_KEY) --push ; \
	} 2>&1 | tee deploy.log
