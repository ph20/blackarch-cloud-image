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
	bash -n build.sh images/*.sh scripts/*.sh scripts/lib/*.sh profiles/*.env
	shellcheck build.sh images/*.sh scripts/*.sh scripts/lib/*.sh profiles/*.env

clean:
	bash ./scripts/clean-build-state.sh

help:
	@printf '%s\n' \
		'Usage: make [target] [BUILD_VERSION=<version>]' \
		'Default profile: IMAGE_PROFILE=generic-qemu.' \
		'Non-root builds prompt for sudo before running ./build.sh.' \
		'Use direct sudo ./build.sh invocations for non-default environment overrides.' \
		'' \
		'Targets:' \
		'  build      Run the staged build pipeline and write artifacts under output/rootfs and output/images' \
		'  check-env  Validate host requirements, sudo availability, and free space' \
		'  lint       Run shell syntax checks and shellcheck' \
		'  clean      Unmount stale tmp/ build leftovers, remove tmp/, and delete versioned build artifacts from output/' \
		'  help       Show this help'
