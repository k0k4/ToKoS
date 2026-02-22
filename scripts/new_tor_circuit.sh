#!/bin/bash
# =============================================================================
# /usr/local/bin/tor-router/new_tor_circuit.sh
# Request a new Tor circuit (new exit IP) via the control port.
# =============================================================================

set -euo pipefail

CONTROL_PORT=9051
AUTH_COOKIE="/var/run/tor/control.authcookie"

if [[ ! -r "$AUTH_COOKIE" ]]; then
    echo "ERROR: Cannot read Tor control cookie: $AUTH_COOKIE" >&2
    exit 1
fi

# Read cookie as hex string
COOKIE=$(xxd -p "$AUTH_COOKIE" | tr -d '\n')

# Send AUTHENTICATE and SIGNAL NEWNYM to the control port
(
    echo -e "AUTHENTICATE $COOKIE\r"
    echo -e "SIGNAL NEWNYM\r"
    echo -e "QUIT\r"
) | nc -q 2 127.0.0.1 "$CONTROL_PORT" > /dev/null

echo "New Tor circuit requested."
