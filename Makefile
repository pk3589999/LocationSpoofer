# Linux sbingner v10 工具链只认老格式 tbd（v3），用 11.4 SDK；插件全是老 API，不受影响
TARGET := iphone:clang:11.4:11.4
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

# rootless 包结构（Dopamine / palera1n rootless 必须）
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# v1.3.0: 产物名故意改成不起眼的样子。
# 钉钉等阿里系 App 的安全 SDK 会枚举进程内已加载的 dylib 路径，
# 之前叫 LocationSpoofer.dylib（字面"定位伪造者"），等于自报家门。
TWEAK_NAME = libtextencoding
libtextencoding_FILES = Tweak.xm
libtextencoding_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
libtextencoding_FRAMEWORKS = Foundation UIKit CoreLocation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
