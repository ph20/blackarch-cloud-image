BUILD_ID ?=
BUILD_VERSION ?=
IMAGE_PROFILES ?= generic-qemu digitalocean
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
SUDO_PRESERVE_ENV := IMAGE_PROFILE,IMAGE_PROFILES,BUILD_ID,BUILD_VERSION,REUSE_ROOTFS,DEFAULT_DISK_SIZE,DISK_SIZE,BLACKARCH_PROFILE,BLACKARCH_PACKAGES,BLACKARCH_KEYRING_VERSION,BLACKARCH_KEYRING_SHA256,BLACKARCH_STRAP_URL,BLACKARCH_STRAP_SHA256,IMAGE_ENABLE_QEMU_GUEST_AGENT,IMAGE_HOSTNAME,IMAGE_SWAP_SIZE,IMAGE_LOCALE,IMAGE_TIMEZONE,IMAGE_KEYMAP,IMAGE_DEFAULT_USER,IMAGE_DEFAULT_USER_GECOS,IMAGE_PASSWORDLESS_SUDO

.PHONY: build build-all publish publish-dry-run weekly-build weekly-build-dry-run weekly-publish weekly-publish-dry-run check-env lint clean help

build: check-env
	@if [ "$$(id -u)" -eq 0 ]; then \
		./build.sh $(BUILD_ARG); \
	else \
		printf '%s\n' 'Root access is required to create loop devices, mount filesystems, install packages, and write the image artifact.'; \
		sudo --preserve-env=$(SUDO_PRESERVE_ENV) -p '[sudo] Enter your password to continue the BlackArch image build for %p: ' ./build.sh $(BUILD_ARG); \
	fi

build-all:
	@if [ "$$(id -u)" -eq 0 ]; then \
		IMAGE_PROFILES='$(IMAGE_PROFILES)' ./scripts/build-all-profiles.sh $(BUILD_ARG); \
	else \
		printf '%s\n' 'Root access is required to create loop devices, mount filesystems, install packages, and write the image artifacts.'; \
		IMAGE_PROFILES='$(IMAGE_PROFILES)' sudo --preserve-env=$(SUDO_PRESERVE_ENV) -p '[sudo] Enter your password to continue the BlackArch multi-profile build for %p: ' ./scripts/build-all-profiles.sh $(BUILD_ARG); \
	fi

publish:
	@bash ./scripts/publish-r2.sh --channel weekly --build-id "$(BUILD_ARG)" --promote-latest

publish-dry-run:
	@bash ./scripts/publish-r2.sh --channel weekly --build-id "$(BUILD_ARG)" --promote-latest --dry-run

weekly-build:
	@IMAGE_PROFILES='$(IMAGE_PROFILES)' BUILD_ID='$(BUILD_ARG)' bash ./scripts/build-weekly.sh $(BUILD_ARG)

weekly-build-dry-run:
	@IMAGE_PROFILES='$(IMAGE_PROFILES)' BUILD_ID='$(BUILD_ARG)' bash ./scripts/build-weekly.sh --dry-run $(BUILD_ARG)

weekly-publish:
	@IMAGE_PROFILES='$(IMAGE_PROFILES)' BUILD_ID='$(BUILD_ARG)' bash ./scripts/build-weekly-publish.sh $(BUILD_ARG)

weekly-publish-dry-run:
	@IMAGE_PROFILES='$(IMAGE_PROFILES)' BUILD_ID='$(BUILD_ARG)' bash ./scripts/build-weekly-publish.sh --dry-run $(BUILD_ARG)

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
		'`make build-all` builds every profile in IMAGE_PROFILES sequentially and reuses the Stage 1 rootfs artifact after the first profile, or immediately when REUSE_ROOTFS=true.' \
		'' \
		'Targets:' \
		'  build      Run the staged build pipeline and write artifacts under output/rootfs and output/images' \
		'  build-all  Build all profiles listed in IMAGE_PROFILES using one BUILD_ID and a reused rootfs tarball' \
		'  publish    Publish an existing weekly BUILD_ID from output/images to R2 without sudo' \
		'  publish-dry-run  Validate and print the planned R2 uploads for BUILD_ID without uploading' \
		'  weekly-build  Build IMAGE_PROFILES for the weekly channel and print publish commands for the resolved BUILD_ID' \
		'  weekly-build-dry-run  Print the planned weekly build-only flow without building or uploading' \
		'  weekly-publish  Build IMAGE_PROFILES, then publish the weekly build to R2' \
		'  weekly-publish-dry-run  Print the planned weekly build/publish commands without building or uploading' \
		'  check-env  Validate host requirements, sudo availability, and free space' \
		'  lint       Run shell syntax checks and shellcheck' \
		'  clean      Unmount stale tmp/ build leftovers, remove tmp/, and delete versioned build artifacts from output/' \
		'  help       Show this help'
