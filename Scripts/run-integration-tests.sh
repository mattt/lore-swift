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
# How long to wait for each server and the provider to answer.
readonly READY_TIMEOUT=30

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
test_pid=""
# Stops the tests, the servers, and the provider, and removes the signing key.
# No command in it can end it early.
# shellcheck disable=SC2329 # The EXIT trap calls it.
clean_up() {
    if [ -n "$test_pid" ] && kill -0 "$test_pid" 2>/dev/null; then
        kill "$test_pid" 2>/dev/null || true
        wait "$test_pid" 2>/dev/null || true
    fi
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
# The tests run in the background so that a signal interrupts the wait for them
# instead of waiting for them to finish.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Waits until a URL answers.
# Fails at once if the process with the given ID exits,
# or after $READY_TIMEOUT seconds if the URL still doesn't answer,
# and prints the end of the process's log.
# The logs can't contain a token at this point, because the tests haven't started,
# and the signing key is never in them.
wait_for() {
    local url="$1" pid="$2" log="$3" problem=""
    local deadline=$((SECONDS + READY_TIMEOUT))
    until curl --silent --fail --connect-timeout 1 --max-time 2 --output /dev/null "$url"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            problem="process $pid exited before $url answered"
        elif [ "$SECONDS" -ge "$deadline" ]; then
            problem="$url did not answer within $READY_TIMEOUT seconds"
        else
            sleep 0.2
            continue
        fi
        echo "error: $problem; the end of $log follows" >&2
        tail -n 20 "$log" | sed 's/^/    /' >&2 || true
        exit 1
    done
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
  "token_endpoint": "$ISSUER/token",
  "revocation_endpoint": "$ISSUER/revoke"
}
EOF
# The provider can take seconds to answer on a CI runner,
# so it starts first and the open server starts while it does.
/usr/bin/python3 "$package_root/Scripts/identity-provider.py" "$PROVIDER_PORT" "$provider/files" \
    >"$provider/provider.log" 2>&1 &
provider_pid=$!
pids="$pids $provider_pid"

write_config "$run/open/config" "$PORT" "$HTTP_PORT" "$run/open/store"
start_server open "$HTTP_PORT"

wait_for "$ISSUER/.well-known/openid-configuration" "$provider_pid" "$provider/provider.log"
echo "identity provider is running (pid $provider_pid); logs in $provider/provider.log"

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
    swift test "$@" &
test_pid=$!
status=0
wait "$test_pid" || status=$?
test_pid=""
exit "$status"
