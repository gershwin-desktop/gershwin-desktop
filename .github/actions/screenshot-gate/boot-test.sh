#!/bin/sh
# boot-test.sh — wait for the live ISO to reach a graphical screen (the
# loginwindow greeter), driven entirely from OUTSIDE the guest.
#
# Streams the guest serial console live (so the CI log shows boot progress and
# you can see it isn't hanging) and polls the VGA framebuffer through the QEMU
# monitor: a text console has very few distinct colors, a painted GUI greeter
# has many. Passes when the framebuffer goes graphical; fails after a bounded wait.
set -u

SOCK=tests/mon.sock
SERIAL=tests/serial.log
FRAMES=tests/frames
DEADLINE_SECS=600          # 10 min hard cap (job has its own timeout too)
COLOR_THRESHOLD=64         # >this many unique colors => treat as graphical

mkdir -p "$FRAMES"
: > "$SERIAL" 2>/dev/null || true

mon() { printf '%s\n' "$*" | socat -t2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true; }
colors() { identify -format '%k' "$1" 2>/dev/null || echo 0; }

# Tee the serial console to the live CI log so progress is visible.
tail -n +1 -f "$SERIAL" 2>/dev/null | sed 's/^/[serial] /' &
TAILPID=$!
trap 'kill "$TAILPID" 2>/dev/null' EXIT INT TERM

echo "[boot-test] waiting for a graphical greeter (<= ${DEADLINE_SECS}s)"
END=$(( $(date +%s) + DEADLINE_SECS ))
i=0
while [ "$(date +%s)" -lt "$END" ]; do
    i=$((i + 1))
    f="$FRAMES/frame-$(printf '%03d' "$i").ppm"
    mon "screendump $f"
    sleep 1
    c=$(colors "$f")
    echo "[boot-test] frame $i: ${c} colors"
    if [ "$c" -gt "$COLOR_THRESHOLD" ] 2>/dev/null; then
        echo "[boot-test] PASS: graphical screen detected (${c} colors) — greeter is up"
        cp "$f" tests/greeter.ppm 2>/dev/null || true
        exit 0
    fi
    sleep 8
done

echo "[boot-test] FAIL: no graphical screen within ${DEADLINE_SECS}s"
echo "[boot-test] last serial lines:"; tail -n 40 "$SERIAL" 2>/dev/null || true
if [ "${GATE_SOFT:-false}" = "true" ]; then
    echo "[boot-test] SOFT mode — continuing so desktop-test can annotate the failure onto the screenshot."
    exit 0
fi
exit 1
