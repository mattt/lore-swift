"""A stub OpenID Connect provider for the authentication integration tests.

Usage: identity-provider.py <port> <directory>

Scripts/run-integration-tests.sh starts it on 127.0.0.1.
It serves the files in <directory>, such as the discovery document
and the key set, and the device authorization flow (RFC 8628):

- POST /device starts a login and returns a device code and a user code.
- POST /approve with `user_code` and `access_token` approves a login,
  as the user would in a browser.
- POST /token with `device_code` returns the access token of an approved login,
  or `authorization_pending`.

It runs with the system Python 3 and uses only the standard library.
"""

import http.server
import json
import secrets
import socketserver
import string
import sys
import threading
import urllib.parse

port = int(sys.argv[1])
directory = sys.argv[2]
issuer = f"http://127.0.0.1:{port}"

lock = threading.Lock()
# Logins by device code: the user code and, once approved, the access token.
logins = {}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *arguments, **keywords):
        super().__init__(*arguments, directory=directory, **keywords)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        form = urllib.parse.parse_qs(self.rfile.read(length).decode())
        field = lambda name: form.get(name, [""])[0]

        if self.path == "/device":
            device_code = secrets.token_urlsafe(16)
            letters = "".join(secrets.choice(string.ascii_uppercase) for _ in range(8))
            user_code = f"{letters[:4]}-{letters[4:]}"
            with lock:
                logins[device_code] = {"user_code": user_code, "access_token": None}
            self.reply(
                200,
                {
                    "device_code": device_code,
                    "user_code": user_code,
                    "verification_uri": f"{issuer}/activate",
                    "expires_in": 60,
                    "interval": 1,
                },
            )
        elif self.path == "/approve":
            with lock:
                for login in logins.values():
                    if login["user_code"] == field("user_code"):
                        login["access_token"] = field("access_token")
                        self.reply(200, {})
                        return
            self.reply(404, {"error": "unknown user code"})
        elif self.path == "/token":
            with lock:
                login = logins.get(field("device_code"))
            if login is None:
                self.reply(400, {"error": "invalid_grant"})
            elif login["access_token"] is None:
                self.reply(400, {"error": "authorization_pending"})
            else:
                self.reply(
                    200,
                    {
                        "access_token": login["access_token"],
                        "token_type": "Bearer",
                        "expires_in": 3600,
                    },
                )
        else:
            self.reply(404, {"error": "not found"})

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *arguments):
        # Requests carry tokens, so the stub logs only the method and path.
        sys.stderr.write(f"{self.command} {self.path.split('?')[0]}\n")


class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind looks up the host's name
        # after it binds the socket and before the socket listens.
        # A slow lookup keeps the server from accepting connections,
        # and the server doesn't use the name.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


server = Server(("127.0.0.1", port), Handler)
sys.stderr.write(f"Listening on {issuer}\n")
server.serve_forever()
