.PHONY: init
init:
	which brew || /bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	brew bundle

.PHONY: xcode
xcode:
	xcodegen
	open ClaudeSquad.xcodeproj

.PHONY: build
build:
	set -o pipefail && xcodebuild -project ClaudeSquad.xcodeproj -scheme ClaudeSquad -configuration Debug build | xcbeautify

.PHONY: test
test:
	set -o pipefail && xcodebuild -project ClaudeSquad.xcodeproj -scheme ClaudeSquad -configuration Debug test | xcbeautify

.PHONY: clean
clean:
	rm -rf ~/Library/Developer/Xcode/DerivedData
