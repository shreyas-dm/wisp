# Wisp build entry points. `make build`, `make test`, `make app`, `make run`.
SHELL := /bin/bash

.PHONY: build test release app run clean

build:
	@source scripts/dev-env.sh && swift build $$WISP_SWIFT_FLAGS

test:
	@source scripts/dev-env.sh && swift run $$WISP_SWIFT_FLAGS WispTests

release:
	@source scripts/dev-env.sh && swift build -c release $$WISP_SWIFT_FLAGS

app: release
	@bash scripts/make-app.sh

run: build
	@./.build/debug/wisp

clean:
	rm -rf .build dist
