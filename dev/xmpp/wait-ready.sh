#!/bin/sh
# Wait until the dev XMPP server really answers on 127.0.0.1:5223.
#
# Docker's healthcheck is `ejabberdctl status`, which says the Erlang node is
# up. It does not say the TLS listener is accepting, and on a fresh CI runner the
# difference was enough to fail a run: the container turned healthy, the tests
# started, and every one of them died at the TLS handshake with an EOF while
# ejabberd's own log showed it still shutting down and starting again. The same
# job passed on a re-run with nothing changed.
#
# So ask the question the tests are about to ask: complete a TLS handshake, and
# verify the certificate against the one the client is told to trust. One success
# is not enough, because the failure above was a server that answered once and
# then went away; the handshake has to succeed several times in a row, a second
# apart, before this returns.
#
# Exits 0 when ready, 1 (with the reason) if it is not ready in time.
set -eu

host="${XMPP_HOST:-127.0.0.1}"
port="${XMPP_PORT:-5223}"
need="${XMPP_READY_STREAK:-3}"
deadline="${XMPP_READY_SECONDS:-90}"

# Run from inside the certs directory with a relative name. A native Windows
# openssl does not understand the /c/... paths a Unix shell on that machine
# hands it (see gen-certs.sh).
cd "$(dirname "$0")/certs"

streak=0
waited=0
while [ "$waited" -lt "$deadline" ]; do
  # `-verify_return_error` makes a bad certificate a failed handshake rather
  # than a warning; stdin is closed so s_client does not wait for input. The
  # `|| true` is for `set -e`: a refused connection is an expected answer here.
  out="$(openssl s_client -connect "$host:$port" -servername localhost \
    -CAfile localhost.crt -verify_return_error </dev/null 2>&1 || true)"
  case "$out" in
    *"Verify return code: 0 (ok)"*) streak=$((streak + 1)) ;;
    *) streak=0 ;;
  esac
  if [ "$streak" -ge "$need" ]; then
    echo "XMPP server is accepting TLS on $host:$port"
    exit 0
  fi
  sleep 1
  waited=$((waited + 1))
done

echo "XMPP server did not complete a TLS handshake on $host:$port within ${deadline}s" >&2
echo "last openssl output:" >&2
printf '%s\n' "$out" | tail -n 8 >&2
exit 1
