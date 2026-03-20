BUILD_VERSION ?=

.PHONY: build check-env lint clean

build: check-env
	if [ "$$(id -u)" -eq 0 ]; then ./build.sh $(BUILD_VERSION); else sudo ./build.sh $(BUILD_VERSION); fi

check-env:
	bash ./scripts/check-build-env.sh

lint:
	bash -n build.sh images/*.sh scripts/*.sh

clean:
	rm -rf output tmp
