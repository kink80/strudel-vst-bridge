BUILD_DIR := build
BUILD_TYPE ?= Debug
JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)
BINARY := $(BUILD_DIR)/strudel-vst-bridge_artefacts/$(BUILD_TYPE)/strudel-vst-bridge.app/Contents/MacOS/strudel-vst-bridge

.PHONY: all configure build run clean rebuild

all: build

configure:
	@mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && cmake .. -DCMAKE_BUILD_TYPE=$(BUILD_TYPE)

build: | configure
	cmake --build $(BUILD_DIR) --target strudel-vst-bridge -j$(JOBS)

run: build
	$(BINARY)

clean:
	rm -rf $(BUILD_DIR)

rebuild: clean build

# Only re-run cmake configure if CMakeLists.txt changed or build dir missing
$(BUILD_DIR)/CMakeCache.txt: CMakeLists.txt
	@mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && cmake .. -DCMAKE_BUILD_TYPE=$(BUILD_TYPE)

configure: $(BUILD_DIR)/CMakeCache.txt
