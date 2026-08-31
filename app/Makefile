# SK Note Taker — build & diagnostics

.PHONY: build app test test-all audiocheck fixtures clean

build:
	swift build

app:
	./scripts/build-app.sh

# Unit tests only (fast, no permissions/models needed).
test:
	swift test

# Full suite: unit + pipeline integration (downloads models) + live Codex CLI.
test-all: fixtures
	SKNOTE_INTEGRATION=1 SKNOTE_AI=1 swift test

# Regenerate synthetic multi-voice meeting fixtures used by the pipeline test.
fixtures:
	./scripts/make-fixtures.sh

# Hardware mic/system check — run from a terminal that has mic permission.
#   make audiocheck ARGS="mic 6"     make audiocheck ARGS="both 8"
audiocheck:
	swift run sknote-audiocheck $(ARGS)

clean:
	swift package clean
	rm -rf dist
