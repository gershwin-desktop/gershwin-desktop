#!/bin/sh
# loginwindow-test.sh — log in as `admin` with no password, from outside the
# guest, by sending keystrokes through the QEMU monitor to the greeter.
#
# Best-effort during bring-up: the exact greeter focus/flow is unverified, so
# this is marked continue-on-error in CI. It captures before/after frames so we
# can see what the login attempt actually did.
set -u

SOCK=tests/mon.sock
mon() { printf '%s\n' "$*" | socat -t2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true; }
key() { mon "sendkey $1"; sleep 0.2; }
type_str() {
    s=$1
    while [ -n "$s" ]; do
        ch=$(printf '%.1s' "$s"); s=${s#?}
        case "$ch" in
            ' ') key spc ;;
            *)   key "$ch" ;;
        esac
    done
}

mon "screendump tests/before-login.ppm"
echo "[loginwindow-test] typing admin / <empty password>"

# Username field (greeter typically focuses it first).
type_str admin
key ret
sleep 1
# Password is empty -> just confirm.
key ret
sleep 5

mon "screendump tests/after-login.ppm"
echo "[loginwindow-test] login keystrokes sent (see before/after-login.ppm)"
