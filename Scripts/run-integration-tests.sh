#!/bin/bash
#
# Runs the test suite with the integration tests enabled,
# against a local loreserver that this script starts and stops.
#
# Usage: Scripts/run-integration-tests.sh [swift test arguments]
#
# Run Scripts/fetch-loreserver.sh first.
# The server listens on 127.0.0.1 only:
# port 43537 for QUIC (UDP) and gRPC (TCP), and port 43539 for HTTP.
# Its stores, logs, and temporary files go in .scratch/integration/.
#
# The script is compatible with Bash 3.2, the system Bash on macOS.

set -euo pipefail

readonly HOST="127.0.0.1"
readonly PORT=43537
readonly HTTP_PORT=43539

package_root="$(cd "$(dirname "$0")/.." && pwd)"
server="$package_root/Vendor/loreserver/loreserver"
run="$package_root/.scratch/integration/$(date +%Y%m%d-%H%M%S)"

if [ ! -x "$server" ]; then
    echo "error: $server is missing; run Scripts/fetch-loreserver.sh" >&2
    exit 1
fi

if lsof -nP -iTCP:"$PORT" -iUDP:"$PORT" -iTCP:"$HTTP_PORT" >/dev/null 2>&1; then
    echo "error: port $PORT or $HTTP_PORT is in use" >&2
    exit 1
fi

mkdir -p "$run/config" "$run/store" "$run/tmp"
cat >"$run/config/local.toml" <<EOF
[server.quic]
host = "$HOST"
port = $PORT

[server.grpc]
host = "$HOST"
port = $PORT

[server.http]
host = "$HOST"
port = $HTTP_PORT

[immutable_store.local]
path = "$run/store"

[mutable_store.local]
path = "$run/store"
EOF

HOME="$run" TMPDIR="$run/tmp/" "$server" --config "$run/config" >"$run/server.log" 2>&1 &
server_pid=$!

stop_server() {
    if kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid"
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap stop_server EXIT

ready=0
for _ in $(seq 1 50); do
    if curl --silent --fail --output /dev/null "http://$HOST:$HTTP_PORT/health_check"; then
        ready=1
        break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        break
    fi
    sleep 0.2
done
if [ "$ready" -ne 1 ]; then
    echo "error: loreserver did not become healthy; see $run/server.log" >&2
    exit 1
fi
echo "loreserver is running (pid $server_pid); logs in $run/server.log"

cd "$package_root"
LORE_INTEGRATION=1 LORE_SERVER_URL="lore://$HOST:$PORT" swift test "$@"
