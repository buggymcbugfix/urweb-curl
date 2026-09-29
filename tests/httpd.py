#!/usr/bin/env python3
"""A fake HTTP server for the tests: one port plain, one with TLS (the
certificate and key given), behaving by path.  Prints http=PORT, https=PORT
and closed=PORT (a port nothing listens on) once it listens, then serves
until killed.  Standard library only.

  /echo            200: the request as seen (method, path, headers but Host
                   and Accept-Encoding, body), one item per line
  /status/N        status N, body "status N"
  /headers         200 with a few headers, one of them twice
  /slow/S          200 after S seconds
  /drop            the connection closed without an answer
  /big/N           200 with N bytes of body
  /redirect/N      302 to /redirect/N-1; /redirect/0 is 200 "landed"
  /gzip            200 with a gzip-compressed body
  /nocontent       204
  /auth            200 if the Authorization header is Basic for user:secret,
                   401 with WWW-Authenticate otherwise
"""

import gzip
import socket
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def answer(self, status, data=b"", headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def handle_any(self):
        path = self.path
        body = self.body()
        if path == "/echo":
            lines = ["method: " + self.command, "path: " + path]
            for name, value in self.headers.items():
                if name.lower() not in ("host", "accept-encoding"):
                    lines.append(name + ": " + value)
            lines.append("body: " + body.decode("utf-8", "replace"))
            self.answer(200, ("\n".join(lines) + "\n").encode(),
                        [("Content-Type", "text/plain; charset=utf-8")])
        elif path.startswith("/status/"):
            n = int(path[len("/status/"):])
            self.answer(n, ("status %d\n" % n).encode(), [("Content-Type", "text/plain")])
        elif path == "/headers":
            self.answer(200, b"with headers\n",
                        [("Content-Type", "text/plain; charset=utf-8"), ("X-One", "1"),
                         ("Set-Cookie", "a=1; Path=/"), ("Set-Cookie", "b=2; Path=/"),
                         ("X-Two", "two  words")])
        elif path.startswith("/slow/"):
            time.sleep(float(path[len("/slow/"):]))
            self.answer(200, b"slowly\n")
        elif path == "/drop":
            self.close_connection = True
            self.connection.close()
        elif path.startswith("/big/"):
            n = int(path[len("/big/"):])
            self.answer(200, (b"0123456789" * (n // 10 + 1))[:n],
                        [("Content-Type", "application/octet-stream")])
        elif path.startswith("/redirect/"):
            n = int(path[len("/redirect/"):])
            if n == 0:
                self.answer(200, b"landed\n")
            else:
                self.answer(302, b"", [("Location", "/redirect/%d" % (n - 1))])
        elif path == "/gzip":
            self.answer(200, gzip.compress(b"was compressed\n"),
                        [("Content-Type", "text/plain"), ("Content-Encoding", "gzip")])
        elif path == "/nocontent":
            self.send_response(204)
            self.end_headers()
        elif path == "/auth":
            if self.headers.get("Authorization") == "Basic dXNlcjpzZWNyZXQ=":
                self.answer(200, b"welcome\n")
            else:
                self.answer(401, b"who are you?\n", [("WWW-Authenticate", 'Basic realm="test"')])
        else:
            self.answer(404, b"nothing here\n")

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = handle_any
    do_PROPFIND = handle_any


def serve(server):
    server.serve_forever()


def main():
    cert, key = sys.argv[1], sys.argv[2]
    plain = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    tls = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    tls.socket = context.wrap_socket(tls.socket, server_side=True)
    # A port nothing listens on: bound once, then closed.
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    closed = s.getsockname()[1]
    s.close()
    for server in (plain, tls):
        threading.Thread(target=serve, args=(server,), daemon=True).start()
    print("http=%d" % plain.server_address[1])
    print("https=%d" % tls.server_address[1])
    print("closed=%d" % closed)
    sys.stdout.flush()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
