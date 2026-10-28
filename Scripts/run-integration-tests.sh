#!/bin/bash
#
# Runs the test suite with the integration tests enabled,
# against two local loreservers that this script starts and stops.
#
# Usage: Scripts/run-integration-tests.sh [swift test arguments]
#
# Run Scripts/fetch-loreserver.sh first.
# The servers listen on 127.0.0.1 only.
# The first accepts every request:
# port 43537 for QUIC (UDP) and gRPC (TCP), and port 43539 for HTTP.
# The second requires tokens:
# port 43547 for QUIC and gRPC, and port 43549 for HTTP.
# Its tokens come from a stub OpenID Connect provider on port 43551
# (Scripts/identity-provider.py, which needs the system Python 3),
# signed with a key that this script generates for each run and removes after it.
# Stores, keys, logs, and temporary files go in .scratch/integration/.
#
# The script is compatible with Bash 3.2, the system Bash on macOS.

set -euo pipefail

readonly HOST="127.0.0.1"
readonly PORT=43537
readonly HTTP_PORT=43539
readonly AUTH_PORT=43547
readonly AUTH_HTTP_PORT=43549
readonly PROVIDER_PORT=43551
readonly ISSUER="http://$HOST:$PROVIDER_PORT"

package_root="$(cd "$(dirname "$0")/.." && pwd)"
server="$package_root/Vendor/loreserver/loreserver"
run="$package_root/.scratch/integration/$(date +%Y%m%d-%H%M%S)"

if [ ! -x "$server" ]; then
    echo "error: $server is missing; run Scripts/fetch-loreserver.sh" >&2
    exit 1
fi

for port in "$PORT" "$HTTP_PORT" "$AUTH_PORT" "$AUTH_HTTP_PORT" "$PROVIDER_PORT"; do
    if lsof -nP -iTCP:"$port" -iUDP:"$port" >/dev/null 2>&1; then
        echo "error: port $port is in use" >&2
        exit 1
    fi
done

pids=""
signing_key=""
# Stops the servers and the provider and removes the signing key.
# No command in it can end it early.
clean_up() {
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    if [ -n "$signing_key" ]; then
        rm -f "$signing_key" || true
    fi
}
trap clean_up EXIT
# Exiting runs the EXIT trap, with the status for the signal.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Waits until a URL answers, or fails if the process with the given ID exits.
wait_for() {
    local url="$1" pid="$2" log="$3"
    for _ in $(seq 1 50); do
        if curl --silent --fail --connect-timeout 1 --max-time 2 --output /dev/null "$url"; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.2
    done
    echo "error: $url did not answer; see $log" >&2
    exit 1
}

# Writes a server configuration that listens on the given ports
# and keeps its stores in the given directory.
write_config() {
    local config="$1" port="$2" http_port="$3" store="$4"
    mkdir -p "$config" "$store"
    cat >"$config/local.toml" <<EOF
[server.quic]
host = "$HOST"
port = $port

[server.grpc]
host = "$HOST"
port = $port

[server.http]
host = "$HOST"
port = $http_port

[immutable_store.local]
path = "$store"

[mutable_store.local]
path = "$store"
EOF
}

# Starts a server with the given configuration and waits until it's healthy.
start_server() {
    local name="$1" http_port="$2"
    mkdir -p "$run/$name/tmp"
    HOME="$run/$name" TMPDIR="$run/$name/tmp/" "$server" --config "$run/$name/config" \
        >"$run/$name/server.log" 2>&1 &
    pids="$pids $!"
    wait_for "http://$HOST:$http_port/health_check" "$!" "$run/$name/server.log"
    echo "loreserver ($name) is running (pid $!); logs in $run/$name/server.log"
}

write_config "$run/open/config" "$PORT" "$HTTP_PORT" "$run/open/store"
start_server open "$HTTP_PORT"

# The provider publishes the public half of a P-256 key
# in its discovery document's key set.
# Only this user can read the private key,
# and the script removes it when it exits.
provider="$run/provider"
mkdir -p "$provider/files/.well-known"
signing_key="$provider/key.pem"
if ! (umask 077 && /usr/bin/openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null |
    /usr/bin/openssl pkcs8 -topk8 -nocrypt -out "$signing_key"); then
    echo "error: could not generate a signing key" >&2
    exit 1
fi
# The last 64 bytes of a P-256 public key in DER form are its coordinates.
/usr/bin/openssl ec -in "$signing_key" -pubout -outform DER 2>/dev/null |
    tail -c 64 >"$provider/public-key"
base64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }
x="$(head -c 32 "$provider/public-key" | base64url)"
y="$(tail -c 32 "$provider/public-key" | base64url)"
cat >"$provider/files/jwks.json" <<EOF
{"keys": [{"kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": "test", "x": "$x", "y": "$y"}]}
EOF
cat >"$provider/files/.well-known/openid-configuration" <<EOF
{
  "issuer": "$ISSUER",
  "jwks_uri": "$ISSUER/jwks.json",
  "device_authorization_endpoint": "$ISSUER/device",
  "token_endpoint": "$ISSUER/token"
}
EOF
/usr/bin/python3 "$package_root/Scripts/identity-provider.py" "$PROVIDER_PORT" "$provider/files" \
    >"$provider/provider.log" 2>&1 &
pids="$pids $!"
wait_for "$ISSUER/.well-known/openid-configuration" "$!" "$provider/provider.log"

# The server verifies tokens against the provider's key set
# and lets any valid token reach every repository.
write_config "$run/authenticated/config" "$AUTH_PORT" "$AUTH_HTTP_PORT" "$run/authenticated/store"
cat >>"$run/authenticated/config/local.toml" <<EOF

[server.auth]
jwt_issuer = ["$ISSUER"]
jwt_audience = ["lore-tests"]

[server.auth.jwk]
endpoint = "$ISSUER/jwks.json"

[server.auth.oidc]
client_id = "lore-tests"
EOF
start_server authenticated "$AUTH_HTTP_PORT"

cd "$package_root"
LORE_INTEGRATION=1 \
    LORE_SERVER_URL="lore://$HOST:$PORT" \
    LORE_AUTHENTICATED_SERVER_URL="lore://$HOST:$AUTH_PORT" \
    LORE_IDENTITY_PROVIDER_URL="$ISSUER" \
    LORE_SIGNING_KEY="$signing_key" \
    swift test "$@"
