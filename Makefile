.DEFAULT_GOAL := help

.PHONY: help project core-test build test

help:
	@printf '%s\n' 'make project  Generate WoowAssistant.xcodeproj with XcodeGen'
	@printf '%s\n' 'make core-test Run locally portable contracts and domain tests'
	@printf '%s\n' 'make build    Build for an iOS Simulator'
	@printf '%s\n' 'make test     Run unit and UI tests on an iOS Simulator'

project:
	xcodegen generate

core-test:
	swift test

build: project
	xcodebuild -project WoowAssistant.xcodeproj -scheme WoowAssistant -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build

test: project
	device_id="$$(xcrun simctl list devices available -j | python3 scripts/select_simulator.py)" && \
	xcodebuild -project WoowAssistant.xcodeproj -scheme WoowAssistant -destination "platform=iOS Simulator,id=$$device_id" test
