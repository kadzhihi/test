ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
THEOS_PACKAGE_ARCH = iphoneos-arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = safarijs
safarijs_FILES = safarijs.m
safarijs_FRAMEWORKS = Foundation CoreFoundation
safarijs_LIBRARIES = xpc
safarijs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
safarijs_CODESIGN_FLAGS = -Sentitlements.plist
safarijs_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk
