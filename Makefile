BUILD_ID ?=
BUILD_VERSION ?=
BUILD_VERSION_IS_BUILD_ID := $(shell printf '%s\n' '$(BUILD_VERSION)' | grep -Eq '^[0-9]{8}\.[0-9]+$$' && printf yes)
ifeq ($(strip $(BUILD_ID)),)
ifeq ($(BUILD_VERSION_IS_BUILD_ID),yes)
BUILD_ARG := $(BUILD_VERSION)
else
BUILD_ARG :=
endif
else
BUILD_ARG := $(BUILD_ID)
endif
SUDO_PRESERVE_ENV := IMAGE_PROFILE,BUILD_ID,BUILD_VERSION,DEFAULT_DISK_SIZE,DISK_SIZE,BLACKARCH_PROFILE,BLACKARCH_PACKAGES,BLACKARCH_KEYRING_VERSION,BLACKARCH_KEYRING_SHA256,BLACKARCH_STRAP_URL,BLACKARCH_STRAP_SHA256,IMAGE_ENABLE_QEMU_GUEST_AGENT,IMAGE_HOSTNAME,IMAGE_SWAP_SIZE,IMAGE_LOCALE,IMAGE_TIMEZONE,IMAGE_KEYMAP,IMAGE_DEFAULT_USER,IMAGE_DEFAULT_USER_GECOS,IMAGE_PASSWORDLESS_SUDO

.PHONY: build check-env lint clean help

build: check-env
	@if [ "$$(id -u)" -eq 0 ]; then \
		./build.sh $(BUILD_ARG); \
	else \
		printf '%s\n' 'Root access is required to create loop devices, mount filesystems, install packages, and write the image artifact.'; \
		sudo --preserve-env=$(SUDO_PRESERVE_ENV) -p '[sudo] Enter your password to continue the BlackArch image build for %p: ' ./build.sh $(BUILD_ARG); \
	fi

check-env:
	bash ./scripts/check-build-env.sh

lint:
	bash -n build.sh images/*.sh scripts/*.sh scripts/lib/*.sh profiles/*.env profiles/*.sh
	shellcheck build.sh images/*.sh scripts/*.sh scripts/lib/*.sh profiles/*.env profiles/*.sh

clean:
	bash ./scripts/clean-build-state.sh

help:
	@printf '%s\n' \
		'Usage: make [target] [BUILD_ID=<YYYYMMDD.N>]' \
		'Default profile: IMAGE_PROFILE=generic-qemu.' \
		'Non-root builds prompt for sudo before running ./build.sh.' \
		'`make build` preserves supported image/build environment overrides across sudo.' \
		'' \
		'Targets:' \
		'  build      Run the staged build pipeline and write artifacts under output/rootfs and output/images' \
		'  check-env  Validate host requirements, sudo availability, and free space' \
		'  lint       Run shell syntax checks and shellcheck' \
		'  clean      Unmount stale tmp/ build leftovers, remove tmp/, and delete versioned build artifacts from output/' \
		'  help       Show this help'
