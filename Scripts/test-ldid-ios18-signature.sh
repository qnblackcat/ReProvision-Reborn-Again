#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT="$PROJECT_DIR/work/ldid-ios18-signature-test"
HARNESS="$TEST_ROOT/ldid-signature-fixture"
INPUT_BINARY="$PROJECT_DIR/work/simulator-build-x86_64/products/Debug-iphonesimulator/ReProvision.app/ReProvision"
SIGNED_BINARY="$TEST_ROOT/ReProvision-signed"
ENTITLEMENTS="$PROJECT_DIR/Tests/Signing/large-entitlements.plist"
EMPTY_ENTITLEMENTS="$PROJECT_DIR/Tests/Signing/empty-entitlements.plist"
PLIST_PREFIX=$(pkg-config --variable=prefix libplist-2.0)

if [ ! -f "$INPUT_BINARY" ]; then
	echo "Build the simulator app before running this test: $INPUT_BINARY" >&2
	exit 1
fi

mkdir -p "$TEST_ROOT"

clang++ -std=c++14 -DLDID_NOSMIME \
	"$PROJECT_DIR/Tests/Signing/ldid_signature_fixture.cpp" \
	"$PROJECT_DIR/Shared/libProvision/ldid/ldid.cpp" \
	-I"$PLIST_PREFIX/include" \
	-L"$PLIST_PREFIX/lib" -lplist-2.0 \
	-o "$HARNESS"

"$HARNESS" "$INPUT_BINARY" "$ENTITLEMENTS" "$SIGNED_BINARY"
chmod +x "$SIGNED_BINARY"

derq macho -i "$SIGNED_BINARY" -o "$TEST_ROOT/entitlements-blob.der"
tail -c +9 "$TEST_ROOT/entitlements-blob.der" >"$TEST_ROOT/entitlements.der"
derq query -i "$TEST_ROOT/entitlements.der" -x -o "$TEST_ROOT/entitlements-from-der.plist"

plutil -lint "$TEST_ROOT/entitlements-from-der.plist"
plutil -extract fixture-dictionary.version raw "$TEST_ROOT/entitlements-from-der.plist" | grep -qx 18
plutil -extract 'com\.apple\.developer\.associated-domains.3' raw "$TEST_ROOT/entitlements-from-der.plist" | \
	grep -qx 'activitycontinuation:fourth-signature-fixture.example.invalid'

# Slot 0 must be the SHA-256 CodeDirectory and slot 0x1000 the legacy
# SHA-1 alternate. These offsets are part of the embedded superblob header.
signature_offset=$(otool -l "$SIGNED_BINARY" | awk '/LC_CODE_SIGNATURE/{found=1} found && /dataoff/{print $2; exit}')
dd if="$SIGNED_BINARY" bs=1 skip="$signature_offset" count=52 2>/dev/null | \
	xxd -p | tr -d '\n' | grep -q '^fade0cc0.*00000000.*00000002.*00000005.*00000007.*00001000'

codesign --verify --strict --verbose=4 "$SIGNED_BINARY"

if [ -n "${SIMULATOR_UDID:-}" ]; then
	SIGNED_APP="$TEST_ROOT/ReProvision.app"
	rm -rf "$SIGNED_APP"
	/usr/bin/ditto "$(dirname "$INPUT_BINARY")" "$SIGNED_APP"
	"$HARNESS" --bundle "$SIGNED_APP" "$EMPTY_ENTITLEMENTS"
	codesign --verify --deep --strict --verbose=4 "$SIGNED_APP"
	xcrun simctl install "$SIMULATOR_UDID" "$SIGNED_APP"
	xcrun simctl launch --terminate-running-process "$SIMULATOR_UDID" jp.soh.reprovision.ios
fi

echo "Validated SHA-256 CodeDirectory and DER entitlements larger than 255 bytes."
echo "DER entitlements: $TEST_ROOT/entitlements.der"
