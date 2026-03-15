DART ?= dart
ENTRY ?= bin/pocketbase_mcp_server.dart
BUILD_DIR ?= build
BIN_NAME ?= pocketbase_mcp

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
NATIVE_OS := macos
else ifeq ($(UNAME_S),Linux)
NATIVE_OS := linux
else
NATIVE_OS := windows
endif

ifeq ($(UNAME_M),x86_64)
NATIVE_ARCH := x64
else ifeq ($(UNAME_M),amd64)
NATIVE_ARCH := x64
else ifeq ($(UNAME_M),aarch64)
NATIVE_ARCH := arm64
else ifeq ($(UNAME_M),arm64)
NATIVE_ARCH := arm64
else
NATIVE_ARCH := x64
endif

.PHONY: help pub-get run aot win mac-amd64 mac-arm64 all-release clean

help:
	@echo "Targets:"
	@echo "  make pub-get      Install Dart dependencies"
	@echo "  make run          Run server with dart run"
	@echo "  make aot          Build native AOT executable for current host"
	@echo "  make win          Cross-compile Windows x64 executable"
	@echo "  make mac-amd64    Cross-compile macOS x64 executable"
	@echo "  make mac-arm64    Cross-compile macOS arm64 executable"
	@echo "  make all-release  Build macOS x64 + macOS arm64 + windows x64"
	@echo "  make clean        Remove build outputs"

pub-get:
	$(DART) pub get

run: pub-get
	$(DART) run

aot: pub-get
	@mkdir -p $(BUILD_DIR)
	$(DART) compile exe $(ENTRY) \
		--target-os=$(NATIVE_OS) \
		--target-arch=$(NATIVE_ARCH) \
		-o $(BUILD_DIR)/$(BIN_NAME)
	@chmod +x $(BUILD_DIR)/$(BIN_NAME) || true
	@echo "Built native executable: $(BUILD_DIR)/$(BIN_NAME)"

win: pub-get
	@mkdir -p $(BUILD_DIR)
	$(DART) compile exe $(ENTRY) \
		--target-os=windows \
		--target-arch=x64 \
		-o $(BUILD_DIR)/$(BIN_NAME).exe
	@echo "Built Windows executable: $(BUILD_DIR)/$(BIN_NAME).exe"

mac-amd64: pub-get
	@mkdir -p $(BUILD_DIR)
	$(DART) compile exe $(ENTRY) \
		--target-os=macos \
		--target-arch=x64 \
		-o $(BUILD_DIR)/$(BIN_NAME)_macos_amd64
	@chmod +x $(BUILD_DIR)/$(BIN_NAME)_macos_amd64 || true
	@echo "Built: $(BUILD_DIR)/$(BIN_NAME)_macos_amd64"

mac-arm64: pub-get
	@mkdir -p $(BUILD_DIR)
	$(DART) compile exe $(ENTRY) \
		--target-os=macos \
		--target-arch=arm64 \
		-o $(BUILD_DIR)/$(BIN_NAME)_macos_arm64
	@chmod +x $(BUILD_DIR)/$(BIN_NAME)_macos_arm64 || true
	@echo "Built: $(BUILD_DIR)/$(BIN_NAME)_macos_arm64"

all-release: mac-amd64 mac-arm64 win

clean:
	rm -rf $(BUILD_DIR)
