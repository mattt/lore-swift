#!/bin/bash
#
# Downloads loreserver from the Lore release on GitHub,
# verifies its SHA-256 digest,
# and installs it in Vendor/loreserver/ for the integration tests.
#
# Usage: Scripts/fetch-loreserver.sh
#
# The script is compatible with Bash 3.2, the system Bash on macOS.

set -euo pipefail

readonly LORE_VERSION="0.12.0"
readonly RELEASE_URL="https://github.com/EpicGames/lore/releases/download/v${LORE_VERSION}"

readonly SERVER_ASSET="loreserver-v${LORE_VERSION}-aarch64-apple-darwin.tar.gz"
readonly SERVER_SHA256="75e2f515e4aa0d71fbfbdede839c3404d18c5761236ec44221c368dc18515f39"

for argument in "$@"; do
    case "$argument" in
    -h | --help)
        sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "error: unknown argument: $argument" >&2
        exit 64
        ;;
    esac
done

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "error: Lore publishes its macOS server for Apple silicon only" >&2
    exit 1
fi

package_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="$package_root/Vendor"
work="$(mktemp -d "${TMPDIR:-/tmp}/fetch-loreserver.XXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "Downloading $SERVER_ASSET"
if ! curl --fail --location --silent --show-error \
    --output "$work/$SERVER_ASSET" "$RELEASE_URL/$SERVER_ASSET"; then
    echo "error: could not download $RELEASE_URL/$SERVER_ASSET" >&2
    exit 1
fi
if ! echo "$SERVER_SHA256  $work/$SERVER_ASSET" | shasum -a 256 --check --status; then
    echo "error: SHA-256 mismatch for $SERVER_ASSET" >&2
    exit 1
fi

mkdir "$work/loreserver"
tar -xzf "$work/$SERVER_ASSET" -C "$work/loreserver"

mkdir -p "$vendor"
rm -rf "$vendor/loreserver"
mkdir "$vendor/loreserver"
cp "$work/loreserver/loreserver" "$work/loreserver/LICENSE.txt" "$vendor/loreserver/"
# The release archive does not set the execute bit.
chmod +x "$vendor/loreserver/loreserver"
echo "Installed Vendor/loreserver/loreserver (Lore $LORE_VERSION)"
