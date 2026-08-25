#!/bin/sh
# Reissue the dev server's certificate so it covers its own onion address.
#
# The onion address is derived from a key pair Tor generates on first start, so
# it is not known when the server's certificate is made and cannot be baked in.
# Without this the two disagree and every connection over Tor fails on the name
# — correctly, since ddIRC verifies certificates for onion addresses exactly as
# it does for any other host.
#
# That is the whole point of the exercise: an onion service reachable from this
# client is one holding a certificate for its `.onion` name. Nothing here is
# weakened to make it work.
#
#   make dev-onion-cert
#
# Run again whenever the onion address changes, which means whenever the Tor
# volume is thrown away (`make dev-server-clean`).
set -eu

cd "$(dirname "$0")"
COMPOSE="docker compose -f compose.yaml"

onion=$(MSYS_NO_PATHCONV=1 $COMPOSE exec -T tor cat //var/lib/tor/ircd/hostname \
        2>/dev/null | tr -d '\r\n') || onion=''
if [ -z "$onion" ]; then
  echo "No onion address yet. Start it with 'make dev-tor' and try again." >&2
  exit 1
fi

echo "onion: $onion"

# CA:FALSE and serverAuth matter. `openssl req -x509` defaults to a CA
# certificate, which rustls then refuses to accept as a server's own — it
# reports `CaUsedAsEndEntity`, which is correct and mystifying.
MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout ergo/privkey.pem -out ergo/fullchain.pem -subj "/O=Ergo" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "subjectAltName=DNS:ergo.test,DNS:localhost,DNS:$onion,IP:127.0.0.1,IP:0:0:0:0:0:0:0:1" \
  2>/dev/null

$COMPOSE restart ircd >/dev/null

echo ""
echo "The dev server's certificate now covers its onion address."
echo "Trust it and connect through Tor:"
echo ""
echo "  SSL_CERT_FILE=dev/ergo/fullchain.pem ddirc-cli \\"
echo "    --server $onion --port 6697 --proxy 127.0.0.1:9050 --nick test"
