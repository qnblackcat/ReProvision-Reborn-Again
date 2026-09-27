#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_ROOT="$PROJECT_DIR/work/simulator-build-x86_64"
PRODUCT_ROOT="$BUILD_ROOT/products"
OBJECT_ROOT="$BUILD_ROOT/intermediates"
MODULE_CACHE="$BUILD_ROOT/module-cache"
UPSTREAM_DEB="$BUILD_ROOT/jp.soh.reprovision_0.8.4-release_iphoneos-arm.deb"
UPSTREAM_ROOT="$BUILD_ROOT/upstream-root"
UPSTREAM_URL="https://havoc.app/api/download/package/62409f4fae64df45281e42c3/jp.soh.reprovision_0.8.4~release_iphoneos-arm.deb"
UPSTREAM_SHA256="84b3d28914e078176578f184ec29d10c7dfc0a1fa8e794934749ddcbab47586b"
RMESSAGE_NIB="$BUILD_ROOT/RMessageView.nib"
RMESSAGE_NIB_OBJECT="49e7f28f72b0e8fd062f8c12ba225160ff65453c:iOS/Package/Applications/ReProvision.app/RMessageView.nib"
RMESSAGE_NIB_SHA256="71b3966d5b9086d1a9533aef6385762f4edd551ed494da1ddbbd4d349e8b1f8b"

EXPECTED_RUNTIME_VERSION=${SIMULATOR_RUNTIME_VERSION:-}

if [ -n "${SIMULATOR_UDID:-}" ]; then
	DEVICE_UDID="$SIMULATOR_UDID"
else
	EXPECTED_RUNTIME_VERSION=${EXPECTED_RUNTIME_VERSION:-17.2}
	DEVICE_UDID=$(xcrun simctl list devices | sed -n "/-- iOS $EXPECTED_RUNTIME_VERSION --/,/^-- /p" | sed -n 's/.*(\([0-9A-F-]*\)) (Booted).*/\1/p' | head -n 1)
fi

if [ -z "$DEVICE_UDID" ]; then
	echo "Boot an iOS $EXPECTED_RUNTIME_VERSION simulator or set SIMULATOR_UDID explicitly." >&2
	exit 1
fi

RUNTIME_VERSION=$(xcrun simctl getenv "$DEVICE_UDID" SIMULATOR_RUNTIME_VERSION)
if [ -n "$EXPECTED_RUNTIME_VERSION" ] && [ "$RUNTIME_VERSION" != "$EXPECTED_RUNTIME_VERSION" ]; then
	echo "Simulator $DEVICE_UDID runs iOS $RUNTIME_VERSION, not iOS $EXPECTED_RUNTIME_VERSION." >&2
	exit 1
fi

SIMULATOR_ROOT=$(xcrun simctl getenv "$DEVICE_UDID" SIMULATOR_ROOT)
RUNTIME_LINK="$PROJECT_DIR/work/simulator-runtime"
ln -sfn "$SIMULATOR_ROOT" "$RUNTIME_LINK"

RESOURCE_APP=${SIMULATOR_RESOURCE_APP:-}
if [ -z "$RESOURCE_APP" ]; then
	for candidate in \
		"$PROJECT_DIR/work/release-extract/root/Applications/ReProvision.app" \
		"$PROJECT_DIR/work/rootless-build/upstream-root/Applications/ReProvision.app" \
		"$UPSTREAM_ROOT/Applications/ReProvision.app"; do
		if [ -d "$candidate/Base.lproj/Main.storyboardc" ] && [ -f "$candidate/Assets.car" ]; then
			RESOURCE_APP="$candidate"
			break
		fi
	done
fi

if [ -z "$RESOURCE_APP" ]; then
	for tool in curl ar shasum tar; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			echo "Missing required tool: $tool" >&2
			exit 1
		fi
	done

	echo "Fetching verified upstream 0.8.4 UI resources..."
	mkdir -p "$BUILD_ROOT" "$UPSTREAM_ROOT"
	curl -L --fail --retry 3 -o "$UPSTREAM_DEB" "$UPSTREAM_URL"
	actual_sha256=$(shasum -a 256 "$UPSTREAM_DEB" | awk '{print $1}')
	if [ "$actual_sha256" != "$UPSTREAM_SHA256" ]; then
		echo "Upstream package checksum mismatch: $actual_sha256" >&2
		exit 1
	fi
	ar p "$UPSTREAM_DEB" data.tar.gz | tar -xzf - -C "$UPSTREAM_ROOT"
	RESOURCE_APP="$UPSTREAM_ROOT/Applications/ReProvision.app"
fi

if [ ! -d "$RESOURCE_APP/Base.lproj/Main.storyboardc" ] || [ ! -f "$RESOURCE_APP/Assets.car" ]; then
	echo "The simulator resource app is incomplete: $RESOURCE_APP" >&2
	exit 1
fi

if [ ! -f "$RMESSAGE_NIB" ] || [ "$(shasum -a 256 "$RMESSAGE_NIB" | awk '{print $1}')" != "$RMESSAGE_NIB_SHA256" ]; then
	mkdir -p "$BUILD_ROOT"
	git -C "$PROJECT_DIR" show "$RMESSAGE_NIB_OBJECT" > "$RMESSAGE_NIB"
fi

if [ "$(shasum -a 256 "$RMESSAGE_NIB" | awk '{print $1}')" != "$RMESSAGE_NIB_SHA256" ]; then
	echo "Historical RMessageView.nib checksum mismatch." >&2
	exit 1
fi

cd "$PROJECT_DIR"

if [ ! -f Pods/Manifest.lock ]; then
	pod install
fi

mkdir -p "$PRODUCT_ROOT" "$OBJECT_ROOT" "$MODULE_CACHE"
xattr -w com.apple.xcode.CreatedByBuildSystem true "$PRODUCT_ROOT" "$OBJECT_ROOT"

COMMON_SETTINGS="ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_USER_SCRIPT_SANDBOXING=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO CLANG_MODULE_CACHE_PATH=$MODULE_CACHE SYMROOT=$PRODUCT_ROOT OBJROOT=$OBJECT_ROOT"
EXCLUDED_RESOURCES="FIRInAppMessageDisplayStoryboard.storyboard Main.storyboard LaunchScreen.storyboard Assets.xcassets GoogleService-Info.plist"
EXCLUDED_STUBS="AuthKit.tbd AuthKitUI.tbd AssertionServices.tbd BackBoardServices.tbd SpringBoardServices.tbd IOKit.tbd Preferences.tbd"
PRIVATE_FRAMEWORKS="$PROJECT_DIR/work/simulator-runtime/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit $PROJECT_DIR/work/simulator-runtime/System/Library/PrivateFrameworks/AuthKitUI.framework/AuthKitUI $PROJECT_DIR/work/simulator-runtime/System/Library/PrivateFrameworks/AssertionServices.framework/AssertionServices $PROJECT_DIR/work/simulator-runtime/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices $PROJECT_DIR/work/simulator-runtime/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices $PROJECT_DIR/work/simulator-runtime/System/Library/PrivateFrameworks/Preferences.framework/Preferences"

xcodebuild -quiet -project Pods/Pods.xcodeproj -target Pods-iOS -configuration Debug \
	-sdk iphonesimulator $COMMON_SETTINGS \
	EXCLUDED_SOURCE_FILE_NAMES="FIRInAppMessageDisplayStoryboard.storyboard" build

xcodebuild -quiet -project ReProvision.xcodeproj -target iOS -configuration Debug \
	-sdk iphonesimulator $COMMON_SETTINGS SIMULATOR_BUILD=1 \
	EXCLUDED_SOURCE_FILE_NAMES="$EXCLUDED_RESOURCES $EXCLUDED_STUBS" \
	OTHER_LDFLAGS="\$(inherited) -ObjC $PRIVATE_FRAMEWORKS -framework IOKit" build

SIMULATOR_APP="$PRODUCT_ROOT/Debug-iphonesimulator/ReProvision.app"
/usr/bin/ditto "$RESOURCE_APP/Base.lproj" "$SIMULATOR_APP/Base.lproj"
cp "$RESOURCE_APP/Assets.car" "$SIMULATOR_APP/Assets.car"
cp "$RMESSAGE_NIB" "$SIMULATOR_APP/RMessageView.nib"
cp "$PROJECT_DIR/Pods/RMessage/RMessage/Assets/RMessageDefaultDesign.json" \
	"$SIMULATOR_APP/RMessageDefaultDesign.json"
for icon_file in "$RESOURCE_APP"/AppIcon*.png; do
	[ -f "$icon_file" ] || continue
	cp "$icon_file" "$SIMULATOR_APP/"
done

codesign --force --sign - "$SIMULATOR_APP/PlugIns/Share.appex"
codesign --force --sign - "$SIMULATOR_APP"
codesign --verify --deep --strict "$SIMULATOR_APP"

xcrun simctl install "$DEVICE_UDID" "$SIMULATOR_APP"
xcrun simctl launch --terminate-running-process "$DEVICE_UDID" jp.soh.reprovision.ios

echo "Installed and launched ReProvision on iOS $RUNTIME_VERSION simulator $DEVICE_UDID"
echo "Simulator app: $SIMULATOR_APP"
