#!/bin/bash
#
# Downloads the Lore C library from the Lore release on GitHub,
# verifies its SHA-256 digest,
# and builds Vendor/liblore.xcframework.zip,
# the archive that the package's binary target downloads.
#
# Usage: Scripts/build-xcframework.sh
#
# The script prints the checksum of the archive
# for the binary target in Package.swift.
# To build against the XCFramework before you publish the archive,
# change the binary target to path: "Vendor/liblore.xcframework".
#
# The script is compatible with Bash 3.2, the system Bash on macOS.

set -euo pipefail

readonly LORE_VERSION="0.12.0"
readonly RELEASE_URL="https://github.com/EpicGames/lore/releases/download/v${LORE_VERSION}"

readonly LIBRARY_ASSET="liblore-v${LORE_VERSION}-aarch64-apple-darwin.tar.gz"
readonly LIBRARY_SHA256="e688f30f2dca6cf72b4da6f8b1f3d0f7ecafdfe374413ee501e344f6ebfd802f"

for argument in "$@"; do
    case "$argument" in
    -h | --help)
        sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "error: unknown argument: $argument" >&2
        exit 64
        ;;
    esac
done

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "error: Lore publishes its macOS library for Apple silicon only" >&2
    exit 1
fi

package_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="$package_root/Vendor"
work="$(mktemp -d "${TMPDIR:-/tmp}/build-xcframework.XXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "Downloading $LIBRARY_ASSET"
if ! curl --fail --location --silent --show-error \
    --output "$work/$LIBRARY_ASSET" "$RELEASE_URL/$LIBRARY_ASSET"; then
    echo "error: could not download $RELEASE_URL/$LIBRARY_ASSET" >&2
    exit 1
fi
if ! echo "$LIBRARY_SHA256  $work/$LIBRARY_ASSET" | shasum -a 256 --check --status; then
    echo "error: SHA-256 mismatch for $LIBRARY_ASSET" >&2
    exit 1
fi

mkdir "$work/liblore"
tar -xzf "$work/$LIBRARY_ASSET" -C "$work/liblore"

for file in liblore.dylib lore.h LICENSE.txt THIRD-PARTY-NOTICES.txt; do
    if [ ! -f "$work/liblore/$file" ]; then
        echo "error: $LIBRARY_ASSET has no $file" >&2
        exit 1
    fi
done

# The headers directory of the XCFramework holds lore.h alone;
# the CLore target of the package supplies the module map.
mkdir "$work/headers"
cp "$work/liblore/lore.h" "$work/headers/lore.h"

mkdir -p "$vendor"
rm -rf "$vendor/liblore.xcframework" "$vendor/liblore.xcframework.zip"
xcodebuild -create-xcframework \
    -library "$work/liblore/liblore.dylib" \
    -headers "$work/headers" \
    -output "$vendor/liblore.xcframework" >/dev/null
cp "$work/liblore/LICENSE.txt" "$vendor/liblore.xcframework/LICENSE.txt"
cp "$work/liblore/THIRD-PARTY-NOTICES.txt" "$vendor/liblore.xcframework/THIRD-PARTY-NOTICES.txt"
echo "Built Vendor/liblore.xcframework (Lore $LORE_VERSION)"

# The archive leaves out extended attributes;
# liblore.dylib keeps its code signature, which is part of the file.
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$vendor/liblore.xcframework" "$vendor/liblore.xcframework.zip"
echo "Built Vendor/liblore.xcframework.zip"

cd "$package_root"
echo "Checksum: $(swift package compute-checksum Vendor/liblore.xcframework.zip)"
