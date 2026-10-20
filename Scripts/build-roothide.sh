#!/bin/sh

set -eu

# roothide packages carry jbroot-based paths (/Applications, /usr/libexec,
# /Library/LaunchDaemons) instead of /var/jb. The app and daemon never touch
# jailbreak paths at runtime, so the binaries built and signed by the rootless
# build are reused as-is and only repackaged here.

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
THEOS_ROOT=${THEOS:-}
ROOTLESS_TREE="$PROJECT_DIR/iOS/RootlessPackage/var/jb"
ROOTHIDE_TEMPLATE="$PROJECT_DIR/iOS/RoothidePackage"
STAGING="$PROJECT_DIR/work/roothide-build/staging"

if [ -z "$THEOS_ROOT" ]; then
	echo "Set THEOS to a Theos installation containing vendor/dm.pl/dm.pl." >&2
	exit 1
fi

if [ "${ROOTHIDE_SKIP_BUILD:-0}" != "1" ]; then
	"$PROJECT_DIR/Scripts/build-rootless.sh"
fi

for required in "$ROOTLESS_TREE/Applications/ReProvision.app/ReProvision" "$ROOTLESS_TREE/usr/libexec/reprovisiond"; do
	if [ ! -f "$required" ]; then
		echo "Missing rootless build output: $required" >&2
		exit 1
	fi
done

rm -rf "$STAGING"
mkdir -p "$STAGING/Applications" "$STAGING/usr/libexec" "$STAGING/Library/LaunchDaemons"

/usr/bin/ditto "$ROOTLESS_TREE/Applications/ReProvision.app" "$STAGING/Applications/ReProvision.app"
cp "$ROOTLESS_TREE/usr/libexec/reprovisiond" "$STAGING/usr/libexec/reprovisiond"
cp "$ROOTHIDE_TEMPLATE/Library/LaunchDaemons/jp.soh.reprovisiond.plist" "$STAGING/Library/LaunchDaemons/"
/usr/bin/ditto "$ROOTHIDE_TEMPLATE/DEBIAN" "$STAGING/DEBIAN"

chmod 0755 "$STAGING/DEBIAN/postinst" "$STAGING/DEBIAN/prerm" \
	"$STAGING/Applications/ReProvision.app/ReProvision" \
	"$STAGING/Applications/ReProvision.app/PlugIns/Share.appex/Share" \
	"$STAGING/usr/libexec/reprovisiond"
chmod 0644 "$STAGING/Library/LaunchDaemons/jp.soh.reprovisiond.plist"
find "$STAGING" -name .DS_Store -delete

if grep -rq "/var/jb" "$STAGING/DEBIAN" "$STAGING/Library"; then
	echo "roothide package still references /var/jb" >&2
	exit 1
fi

mkdir -p "$PROJECT_DIR/iOS/CydiaPackages"
/usr/bin/perl "$THEOS_ROOT/vendor/dm.pl/dm.pl" -Zgzip "$STAGING" "$PROJECT_DIR/iOS/CydiaPackages"

echo "roothide package created in $PROJECT_DIR/iOS/CydiaPackages"
