# Thin convenience wrappers around scripts/. See README "Development".
.PHONY: run dev-cert build test lint

# Build, sign (with the stable dev identity if set up), and launch the app.
run:
	scripts/run.sh

# One-time: create the stable self-signed dev code-signing identity so
# macOS stops re-prompting for permissions / keychain on every rebuild.
dev-cert:
	scripts/make_dev_cert.sh

# Build the .app bundle (release config) → build/Unison.app
build:
	scripts/bundle_app.sh

test:
	scripts/test.sh

lint:
	scripts/lint.sh
