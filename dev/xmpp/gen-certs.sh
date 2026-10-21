#!/bin/sh
# A self-signed certificate for the dev XMPP server, if there is not one yet.
#
# For `localhost` and `conference.localhost`, the two names the server answers
# to. The client verifies against the *account's domain* (alice@localhost), not
# against where it dialled, so 127.0.0.1:5223 works with a certificate for
# `localhost` - no second name, and nothing about the client's TLS path changes.
#
# Self-signed rather than issued by a throwaway CA because the tests trust this
# one file directly, the way they trust dev/ergo/fullchain.pem. Three files, all
# in certs/ and all git-ignored, because one is a private key:
#
#   localhost.crt   the certificate, which the client is told to trust
#   localhost.key   its key
#   server.pem      both in one file, which is the shape ejabberd reads
set -eu

dir="$(cd "$(dirname "$0")" && pwd)/certs"
mkdir -p "$dir"

if [ -f "$dir/server.pem" ] && [ -f "$dir/localhost.crt" ]; then
  exit 0
fi

# Run from inside the directory, with relative names. A native Windows openssl
# does not understand the /c/... paths a Unix shell on that machine hands it,
# and MSYS_NO_PATHCONV is needed for the other half of the problem: Git for
# Windows rewrites an argument that starts with a slash, which turns
# "/CN=localhost" into a path and the command into an error.
cd "$dir"
MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825   -keyout localhost.key -out localhost.crt   -subj "/CN=localhost"   -addext "subjectAltName=DNS:localhost,DNS:conference.localhost"   -addext "basicConstraints=critical,CA:FALSE"   -addext "keyUsage=critical,digitalSignature,keyEncipherment"   -addext "extendedKeyUsage=serverAuth" 2>/dev/null

cat "$dir/localhost.crt" "$dir/localhost.key" > "$dir/server.pem"

# The server runs as its own user in the container and has to read these. A dev
# server on loopback, with a certificate nothing else trusts.
chmod 644 "$dir/localhost.key" "$dir/localhost.crt" "$dir/server.pem"
echo "wrote $dir/localhost.crt"
