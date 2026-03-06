.PHONY: init
init:
	which brew || /bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	brew bundle
	rbenv install --skip-existing
	rbenv exec gem install bundler
	rbenv exec bundle install

.PHONY: arkana
arkana:
	rbenv exec bundle exec arkana

.PHONY: xcode
xcode:
	make arkana
	git submodule update --init --recursive
	xcodegen
	open ClaudeSquad.xcodeproj

.PHONY: build
build:
	set -o pipefail && xcodebuild -project ClaudeSquad.xcodeproj -scheme ClaudeSquad -configuration Debug build | xcbeautify

.PHONY: test
test:
	set -o pipefail && xcodebuild -project ClaudeSquad.xcodeproj -scheme ClaudeSquad -configuration Debug test | xcbeautify

.PHONY: screenshots
screenshots:
	./scripts/take-screenshots.sh

.PHONY: clean
clean:
	rm -rf ~/Library/Developer/Xcode/DerivedData
