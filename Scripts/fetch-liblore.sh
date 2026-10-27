#!/bin/bash
#
# Downloads the Lore C library from the Lore release on GitHub,
# verifies its SHA-256 digest,
# and builds Vendor/liblore.xcframework for the package to link against.
#
# Usage: Scripts/fetch-liblore.sh [--with-server]
#
# With --with-server, the script also downloads loreserver
# from the same release into Vendor/loreserver/,
# for the integration tests.
#
# The script is compatible with Bash 3.2, the system Bash on macOS.

set -euo pipefail

readonly LORE_VERSION="0.11.0"
readonly RELEASE_URL="https://github.com/EpicGames/lore/releases/download/v${LORE_VERSION}"

readonly LIBRARY_ASSET="liblore-v${LORE_VERSION}-aarch64-apple-darwin.tar.gz"
readonly LIBRARY_SHA256="1c106da32672bca7be81a699898715fa8adfffd0e97120915e2a3a246a68457e"

readonly SERVER_ASSET="loreserver-v${LORE_VERSION}-aarch64-apple-darwin.tar.gz"
readonly SERVER_SHA256="11445cb42d6a03bbd1c4285b5363c5fa38855fe8186b109d1daa769032f49ebd"

with_server=0
for argument in "$@"; do
    case "$argument" in
    --with-server) with_server=1 ;;
    -h | --help)
        sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
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
work="$(mktemp -d "${TMPDIR:-/tmp}/fetch-liblore.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Downloads a release asset into the work directory and checks its digest.
download() {
    local asset="$1" sha256="$2"
    echo "Downloading $asset"
    if ! curl --fail --location --silent --show-error \
        --output "$work/$asset" "$RELEASE_URL/$asset"; then
        echo "error: could not download $RELEASE_URL/$asset" >&2
        exit 1
    fi
    if ! echo "$sha256  $work/$asset" | shasum -a 256 --check --status; then
        echo "error: SHA-256 mismatch for $asset" >&2
        exit 1
    fi
}

# Extracts an archive into a new, empty directory.
extract() {
    local asset="$1" destination="$2"
    mkdir "$destination"
    tar -xzf "$work/$asset" -C "$destination"
}

download "$LIBRARY_ASSET" "$LIBRARY_SHA256"
extract "$LIBRARY_ASSET" "$work/liblore"

for file in liblore.dylib lore.h LICENSE.txt; do
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
rm -rf "$vendor/liblore.xcframework"
xcodebuild -create-xcframework \
    -library "$work/liblore/liblore.dylib" \
    -headers "$work/headers" \
    -output "$vendor/liblore.xcframework" >/dev/null
cp "$work/liblore/LICENSE.txt" "$vendor/liblore.xcframework/LICENSE.txt"
cp "$work/liblore/THIRD-PARTY-NOTICES.txt" "$vendor/liblore.xcframework/THIRD-PARTY-NOTICES.txt"
echo "Built Vendor/liblore.xcframework (Lore $LORE_VERSION)"

if [ "$with_server" -eq 1 ]; then
    download "$SERVER_ASSET" "$SERVER_SHA256"
    extract "$SERVER_ASSET" "$work/loreserver"
    rm -rf "$vendor/loreserver"
    mkdir "$vendor/loreserver"
    cp "$work/loreserver/loreserver" "$work/loreserver/LICENSE.txt" "$vendor/loreserver/"
    # The release archive does not set the execute bit.
    chmod +x "$vendor/loreserver/loreserver"
    echo "Installed Vendor/loreserver/loreserver (Lore $LORE_VERSION)"
fi
