APP_NAME = SonyConnect
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
TOOLCHAIN_DEVELOPER_PATH := $(shell xcode-select -p)

# Some standalone Command Line Tools releases ship Swift Testing outside the
# default compiler/runtime search paths. Full Xcode configures these itself.
ifeq ($(notdir $(TOOLCHAIN_DEVELOPER_PATH)),CommandLineTools)
TEST_FRAMEWORKS = $(TOOLCHAIN_DEVELOPER_PATH)/Library/Developer/Frameworks
TEST_INTEROP_LIBS = $(TOOLCHAIN_DEVELOPER_PATH)/Library/Developer/usr/lib
SWIFT_TEST_FLAGS = \
	-Xswiftc -F -Xswiftc $(TEST_FRAMEWORKS) \
	-Xlinker -F$(TEST_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(TEST_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(TEST_INTEROP_LIBS)
endif

.PHONY: all build test app run clean

all: app

build:
	swift build -c release

test:
	swift test $(SWIFT_TEST_FLAGS)

app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	codesign --force --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

run: app
	-pkill -f "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" 2>/dev/null
	@sleep 0.3
	open $(APP_BUNDLE)

clean:
	rm -rf .build $(APP_BUNDLE)
