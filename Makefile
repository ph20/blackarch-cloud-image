BUILD_VERSION ?=

.PHONY: build lint clean

build:
	sudo ./build.sh $(BUILD_VERSION)

lint:
	bash -n build.sh images/*.sh scripts/*.sh

clean:
	rm -rf output tmp
