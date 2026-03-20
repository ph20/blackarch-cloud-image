BUILD_VERSION ?=

.PHONY: build check-env lint clean help

build: check-env
	@if [ "$$(id -u)" -eq 0 ]; then \
		./build.sh $(BUILD_VERSION); \
	else \
		printf '%s\n' 'Root access is required to create loop devices, mount filesystems, install packages, and write the image artifact.'; \
		sudo -p '[sudo] Enter your password to continue the BlackArch image build for %p: ' ./build.sh $(BUILD_VERSION); \
	fi

check-env:
	bash ./scripts/check-build-env.sh

lint:
	bash -n build.sh images/*.sh scripts/*.sh
	shellcheck build.sh images/*.sh scripts/*.sh

clean:
	rm -rf output tmp

help:
	@printf '%s\n' \
		'Usage: make [target] [BUILD_VERSION=<version>]' \
		'Non-root builds prompt for sudo before running ./build.sh.' \
		'' \
		'Targets:' \
		'  build      Run preflight checks and build the image (default; prompts for sudo when needed)' \
		'  check-env  Validate host requirements, sudo availability, and free space' \
		'  lint       Run shell syntax checks and shellcheck' \
		'  clean      Remove output/ and tmp/' \
		'  help       Show this help'
