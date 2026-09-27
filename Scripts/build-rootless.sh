#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
THEOS_ROOT=${THEOS:-}
BUILD_ROOT="$PROJECT_DIR/work/rootless-build"
PRODUCT_ROOT="$BUILD_ROOT/products"
OBJECT_ROOT="$BUILD_ROOT/intermediates"
UPSTREAM_DEB="$BUILD_ROOT/jp.soh.reprovision_0.8.4-release_iphoneos-arm.deb"
UPSTREAM_ROOT="$BUILD_ROOT/upstream-root"
UPSTREAM_URL="https://havoc.app/api/download/package/62409f4fae64df45281e42c3/jp.soh.reprovision_0.8.4~release_iphoneos-arm.deb"
UPSTREAM_SHA256="84b3d28914e078176578f184ec29d10c7dfc0a1fa8e794934749ddcbab47586b"
RESOURCE_APP=${ROOTLESS_RESOURCE_APP:-"$UPSTREAM_ROOT/Applications/ReProvision.app"}
RMESSAGE_NIB="$BUILD_ROOT/RMessageView.nib"
RMESSAGE_NIB_OBJECT="49e7f28f72b0e8fd062f8c12ba225160ff65453c:iOS/Package/Applications/ReProvision.app/RMessageView.nib"
RMESSAGE_NIB_SHA256="71b3966d5b9086d1a9533aef6385762f4edd551ed494da1ddbbd4d349e8b1f8b"

if [ -z "$THEOS_ROOT" ]; then
	echo "Set THEOS to a Theos installation containing vendor/dm.pl/dm.pl." >&2
	exit 1
fi

if [ ! -f "$THEOS_ROOT/vendor/dm.pl/dm.pl" ]; then
	echo "Missing package builder: $THEOS_ROOT/vendor/dm.pl/dm.pl" >&2
	exit 1
fi

if ! command -v pod >/dev/null 2>&1; then
	echo "CocoaPods is required. Install it and run this script again." >&2
	exit 1
fi

if [ ! -d "$RESOURCE_APP/Base.lproj/Main.storyboardc" ] || [ ! -f "$RESOURCE_APP/Assets.car" ]; then
	if [ -n "${ROOTLESS_RESOURCE_APP:-}" ]; then
		echo "ROOTLESS_RESOURCE_APP does not contain the compiled ReProvision 0.8.4 UI resources." >&2
		exit 1
	fi

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
fi

if [ ! -f "$RMESSAGE_NIB" ] || [ "$(shasum -a 256 "$RMESSAGE_NIB" | awk '{print $1}')" != "$RMESSAGE_NIB_SHA256" ]; then
	mkdir -p "$BUILD_ROOT"
	git show "$RMESSAGE_NIB_OBJECT" > "$RMESSAGE_NIB"
fi

actual_rmessage_sha256=$(shasum -a 256 "$RMESSAGE_NIB" | awk '{print $1}')
if [ "$actual_rmessage_sha256" != "$RMESSAGE_NIB_SHA256" ]; then
	echo "Historical RMessageView.nib checksum mismatch: $actual_rmessage_sha256" >&2
	exit 1
fi

cd "$PROJECT_DIR"

if [ ! -f Pods/Manifest.lock ]; then
	pod install
fi

mkdir -p "$PRODUCT_ROOT" "$OBJECT_ROOT" "$BUILD_ROOT/module-cache"
xattr -w com.apple.xcode.CreatedByBuildSystem true "$PRODUCT_ROOT" "$OBJECT_ROOT"

COMMON_SETTINGS="ARCHS=arm64 ONLY_ACTIVE_ARCH=NO IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_USER_SCRIPT_SANDBOXING=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO CLANG_MODULE_CACHE_PATH=$BUILD_ROOT/module-cache SYMROOT=$PRODUCT_ROOT OBJROOT=$OBJECT_ROOT"
EXCLUDED_RESOURCES="FIRInAppMessageDisplayStoryboard.storyboard Main.storyboard LaunchScreen.storyboard Assets.xcassets GoogleService-Info.plist"

# Clean the app products first so the subsequent Pods build remains available
# to the final application link step.
xcodebuild -quiet -project ReProvision.xcodeproj -target iOS -configuration Release \
	-sdk iphoneos $COMMON_SETTINGS ROOTLESS_PACKAGE=1 clean

xcodebuild -quiet -project Pods/Pods.xcodeproj -target Pods-iOS -configuration Release \
	-sdk iphoneos $COMMON_SETTINGS EXCLUDED_SOURCE_FILE_NAMES="$EXCLUDED_RESOURCES" clean build

CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache" \
THEOS="$THEOS_ROOT" \
xcodebuild -quiet -project ReProvision.xcodeproj -target iOS -configuration Release \
	-sdk iphoneos $COMMON_SETTINGS EXCLUDED_SOURCE_FILE_NAMES="$EXCLUDED_RESOURCES" \
	ROOTLESS_PACKAGE=1 ROOTLESS_RESOURCE_APP="$RESOURCE_APP" \
	ROOTLESS_RMESSAGE_NIB="$RMESSAGE_NIB" iOSOpenDevPath="$THEOS_ROOT" build

cp "$RMESSAGE_NIB" "$PROJECT_DIR/iOS/RootlessPackage/var/jb/Applications/ReProvision.app/RMessageView.nib"
cp "$PROJECT_DIR/Pods/RMessage/RMessage/Assets/RMessageDefaultDesign.json" \
	"$PROJECT_DIR/iOS/RootlessPackage/var/jb/Applications/ReProvision.app/RMessageDefaultDesign.json"

# The ldid2 binary bundled with this project predates arm64e-era CoreTrust. It
# emits a CodeDirectory v=20001 signature without DER entitlements, which iOS
# 17 rejects at exec time with errno 85 ("Bad executable"). Re-sign every
# packaged executable with a current ldid before building the rootless .deb.
ROOTLESS_LDID=${ROOTLESS_LDID:-$(command -v ldid || true)}
if [ -z "$ROOTLESS_LDID" ] || [ ! -x "$ROOTLESS_LDID" ]; then
	echo "A current ldid is required to create an iOS 17-compatible package." >&2
	exit 1
fi

APP_DIR="$PROJECT_DIR/iOS/RootlessPackage/var/jb/Applications/ReProvision.app"
DAEMON_PATH="$PROJECT_DIR/iOS/RootlessPackage/var/jb/usr/libexec/reprovisiond"
"$ROOTLESS_LDID" -S"$PROJECT_DIR/Shared/entitlements.xml" "$APP_DIR/PlugIns/Share.appex/Share"
"$ROOTLESS_LDID" -S"$PROJECT_DIR/Shared/entitlements.xml" "$APP_DIR/ReProvision"
"$ROOTLESS_LDID" -S"$PROJECT_DIR/Shared/Daemon/entitlements.plist" "$DAEMON_PATH"

for executable in "$APP_DIR/ReProvision" "$APP_DIR/PlugIns/Share.appex/Share" "$DAEMON_PATH"; do
	if ! codesign -dvvv "$executable" 2>&1 | grep -Eq 'CodeDirectory v=(20400|20500|20600)'; then
		echo "Modern code signature verification failed for $executable" >&2
		exit 1
	fi
done

chmod 0755 "$PROJECT_DIR/iOS/RootlessPackage/DEBIAN/postinst" "$PROJECT_DIR/iOS/RootlessPackage/DEBIAN/prerm"
/usr/bin/perl "$THEOS_ROOT/vendor/dm.pl/dm.pl" -Zgzip \
	"$PROJECT_DIR/iOS/RootlessPackage" "$PROJECT_DIR/iOS/CydiaPackages"

echo "Rootless package created in $PROJECT_DIR/iOS/CydiaPackages"
