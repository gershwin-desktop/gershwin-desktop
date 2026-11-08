#!/bin/sh
# boot-test.sh — wait for the live ISO to reach a graphical screen (the
# loginwindow greeter), driven entirely from OUTSIDE the guest.
#
# Streams the guest serial console live (so the CI log shows boot progress and
# you can see it isn't hanging) and polls the VGA framebuffer through the QEMU
# monitor: a text console has very few distinct colors, a painted GUI greeter
# has many. Fails after a bounded wait.
#
# A colourful frame alone is not the greeter: a boot splash (a solid colour, a
# cube and an anti-aliased spinner) also has more than 64 colours, and typing
# the login blind into the splash would make loginwindow-test miss the greeter.
# So a graphical frame passes only when
#   (a) OCR reads the greeter panel (its field labels or buttons), or
#   (b) it is stable (identical to the previous poll and to a re-dump taken a
#       moment later, so a spinning splash cannot pass) AND differs from the
#       first graphical frame seen (the splash, when there is one), or
#   (c) it is unchanged across STABLE_POLLS consecutive polls (~30 s). A live
#       splash spinner never holds still that long; this covers a greeter that
#       is the first graphical frame and that OCR cannot read (e.g. dark text
#       over a busy wallpaper).
set -u

SOCK=tests/mon.sock
SERIAL=tests/serial.log
FRAMES=tests/frames
DEADLINE_SECS=600          # 10 min hard cap (job has its own timeout too)
COLOR_THRESHOLD=64         # >this many unique colors => treat as graphical
STABLE_POLLS=4             # identical graphical frames in a row => settled

mkdir -p "$FRAMES"
: > "$SERIAL" 2>/dev/null || true

mon() { printf '%s\n' "$*" | socat -t2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true; }
colors() { identify -format '%k' "$1" 2>/dev/null || echo 0; }
same()   { cmp -s "$1" "$2"; }
im() { magick "$@" 2>/dev/null || convert "$@" 2>/dev/null; }
# OCR the frame; tesseract and ImageMagick are installed by action.yml. The
# full frame first, then the centre (where the greeter panel sits) greyscaled,
# as a uniform block and as sparse text: over a busy wallpaper a full-frame
# pass can miss the panel's labels entirely.
ocr() {
    command -v tesseract >/dev/null 2>&1 || return 1
    im "$1" -resize 200% "$1.png" && tesseract "$1.png" - 2>/dev/null | tr -d '\r'
    im "$1" -gravity center -crop 60%x80%+0+0 +repage -colorspace Gray -resize 200% "$1.c.png" || return 0
    tesseract "$1.c.png" - --psm 6 2>/dev/null | tr -d '\r'
    tesseract "$1.c.png" - --psm 11 2>/dev/null | tr -d '\r'
}
# Greeter panel text: the field labels and the buttons. The hostname title is
# not used, because the loader menu also prints "NextBSD" and a graphical
# loader screen must not pass either.
GREETER_RE='user[[:space:]]*name|password|log[[:space:]]*in|shut[[:space:]]*down|restart'

# Tee the serial console to the live CI log so progress is visible.
tail -n +1 -f "$SERIAL" 2>/dev/null | sed 's/^/[serial] /' &
TAILPID=$!
trap 'kill "$TAILPID" 2>/dev/null' EXIT INT TERM

echo "[boot-test] waiting for a graphical greeter (<= ${DEADLINE_SECS}s)"
END=$(( $(date +%s) + DEADLINE_SECS ))
i=0
first=""     # first graphical frame (the splash, if the ISO has one)
prev=""      # previous graphical frame
run=0        # how many graphical frames in a row were identical
while [ "$(date +%s)" -lt "$END" ]; do
    i=$((i + 1))
    f="$FRAMES/frame-$(printf '%03d' "$i").ppm"
    mon "screendump $f"
    sleep 1
    c=$(colors "$f")
    echo "[boot-test] frame $i: ${c} colors"
    if [ "$c" -gt "$COLOR_THRESHOLD" ] 2>/dev/null; then
        [ -n "$first" ] || { first="$f"; echo "[boot-test] frame $i: first graphical frame"; }
        if ocr "$f" | grep -qiE "$GREETER_RE"; then
            echo "[boot-test] PASS: greeter text read on frame $i (${c} colors) — greeter is up"
            cp "$f" tests/greeter.ppm 2>/dev/null || true
            exit 0
        fi
        if [ -n "$prev" ] && [ "$f" != "$first" ] && same "$f" "$prev" && ! same "$f" "$first"; then
            r="$f.recheck.ppm"
            sleep 0.3
            mon "screendump $r"
            sleep 1
            if same "$f" "$r"; then
                echo "[boot-test] PASS: stable graphical frame $i, unlike the first graphical frame (${c} colors) — greeter is up"
                cp "$f" tests/greeter.ppm 2>/dev/null || true
                exit 0
            fi
        fi
        if [ -n "$prev" ] && same "$f" "$prev"; then run=$((run + 1)); else run=1; fi
        if [ "$run" -ge "$STABLE_POLLS" ]; then
            echo "[boot-test] PASS: graphical frame unchanged for $run polls (${c} colors) — greeter is up"
            cp "$f" tests/greeter.ppm 2>/dev/null || true
            exit 0
        fi
        echo "[boot-test] frame $i: graphical, but not the greeter yet (splash or still drawing)"
        prev="$f"
    else
        prev=""; run=0
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
