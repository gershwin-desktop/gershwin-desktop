#!/bin/sh
# desktop-test.sh — the interactive desktop gate, driven entirely from OUTSIDE
# the guest over the QEMU monitor (screendump + sendkey; no mouse, nothing
# installed in-guest). Each numbered step is a gate. In HARD mode (rc) the first
# failure exits non-zero and blocks the publish. In SOFT mode (dev, GATE_SOFT=true)
# failures are recorded to screenshot/gate-failures.txt (the publish step lists
# them as red text under the screenshot in the release body) and the job still
# succeeds so the dev ISO ships (we investigate from the release).
#
#   1. desktop rendered  — OCR must find BOTH "System Disk" and "Workspace"
#   2. discover Command  — probe sendkey modifiers until Cmd+R opens the Run…
#                          dialog ("Type the command to execute:")
#   3. close everything  — Cmd+W a few times
#   4. open About        — Cmd+R, type "uitest aboutcomputer", Enter
#   5. About is up       — OCR must find "About This Computer" AND "Workspace"
#                          (the menu bar must still be present at capture time)
#   6. capture           — screendump THIS frame -> screenshot/gershwin-on-<flavor>.png,
#                          the ONLY published screenshot (About This Computer + desktop)
#
# The Command modifier and the About-opening command are the two things that can
# only be confirmed on a real boot, so step 2 auto-probes the modifier and each
# failure prints a precise, actionable reason (wrong modifier vs. uitest/-d).
set -u

SOCK=tests/mon.sock
DESKTOP_DEADLINE=120
ABOUT_DEADLINE=25
CMD="${GATE_ABOUT_CMD:-uitest aboutcomputer}"            # run via the Run… dialog
MODS="${GATE_CMD_MODS:-meta_l alt altgr meta_r ctrl}"    # GNUstep Command modifier — probed
FLAVOR="${GATE_FLAVOR:-desktop}"                         # which flavor we're testing (from the caller workflow)
SHOT="screenshot/gershwin-on-${FLAVOR}.png"              # the ONE published screenshot
SOFT="${GATE_SOFT:-false}"                               # dev channel: don't block — publish anyway,
                                                         # stamp the failed checks onto the screenshot in red

mon()  { printf '%s\n' "$*" | socat -t2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true; }
key()  { mon "sendkey $1"; sleep 0.25; }
park() {   # shove the (relative PS/2) pointer hard into the bottom-right corner so
    # it doesn't sit over the centred About window in the published screenshot.
    mon "mouse_move 20000 20000"; sleep 0.4;
}
dump() { mon "screendump $1"; sleep 0.6; }
ocr()  {   # OCR the whole frame (reads the menu bar: "Workspace", etc.)
    command -v tesseract >/dev/null 2>&1 || return 1
    magick "$1" -resize 200% "$1.png" 2>/dev/null || convert "$1" -resize 200% "$1.png" 2>/dev/null || return 1
    tesseract "$1.png" - 2>/dev/null | tr -d '\r'
}
ocr_corner() {   # OCR just the top-right corner where the "System Disk" volume
    # icon lives. Its ~11px label is invisible to a full-frame OCR pass but reads
    # cleanly cropped, greyscaled and upscaled hard. CRITICAL: the crop must start
    # BELOW the menu bar (+0+28) — if it includes the top row, tesseract locks onto
    # the big "CPU/RAM/clock" menu-bar text and drops the tiny label entirely. With
    # the menu bar excluded, --psm 6 (single uniform block) reads "System Disk"
    # reliably; the default psm 3 and the sparse modes (psm 11/12) do not. Verified
    # against real captured frames.
    command -v tesseract >/dev/null 2>&1 || return 1
    magick "$1" -gravity NorthEast -crop 42%x14%+0+28 +repage -colorspace Gray -resize 400% "$1.ne.png" 2>/dev/null \
      || convert "$1" -gravity NorthEast -crop 42%x14%+0+28 +repage -colorspace Gray -resize 400% "$1.ne.png" 2>/dev/null || return 1
    tesseract "$1.ne.png" - --psm 6 2>/dev/null | tr -d '\r'
}
has() { printf '%s' "$2" | grep -qiE "$1"; }             # has REGEX TEXT
type_str() {
    s=$1
    while [ -n "$s" ]; do
        ch=$(printf '%.1s' "$s"); s=${s#?}
        case "$ch" in ' ') key spc ;; *) key "$ch" ;; esac
    done
}
relogin() {   # re-submit the greeter login. The loginwindow step fires its
    # keystrokes once, early — if the greeter wasn't interactive yet (a slow
    # flavor can pass boot-test on a not-quite-ready frame), 'admin' half-lands
    # and never submits. Clear the field, retype admin, and submit via BOTH the
    # Enter and Tab->Enter flows. Only ever called while the greeter is still
    # on-screen (see the OCR guard below), so it can't disturb a live desktop.
    n=0; while [ "$n" -lt 24 ]; do key backspace; n=$((n + 1)); done
    type_str admin
    key ret; sleep 0.6; key tab; sleep 0.3; key ret; sleep 0.6; key ret
}
save_shot() {   # copy $1 (or a fresh screendump) to the published $SHOT
    if [ -n "${1:-}" ] && [ -s "${1:-}" ]; then cp "$1" tests/desktop.ppm 2>/dev/null || true
    else mon "screendump tests/desktop.ppm"; sleep 1; fi
    magick tests/desktop.ppm "$SHOT" 2>/dev/null || convert tests/desktop.ppm "$SHOT" 2>/dev/null || true
}

# --- failure handling ---------------------------------------------------------
# Hard mode (rc): the first failed check exits non-zero and blocks the publish.
# Soft mode (dev, GATE_SOFT=true): failed checks are recorded and stamped onto the
# published screenshot in red, but the job still succeeds so the dev ISO ships.
FAILS=""; LAST=""
add_fail() { FAILS="${FAILS}${FAILS:+; }$1"; }
write_failures() {   # record the failed checks (one per line) for the publish step
    # to render under the screenshot in the release body. The screenshot itself is
    # left clean — the failure list is text, not baked into the image.
    mkdir -p screenshot
    : > screenshot/gate-failures.txt
    [ -n "$FAILS" ] && printf '%s' "$FAILS" | tr ';' '\n' | sed 's/^ *//; /^$/d' \
        > screenshot/gate-failures.txt
}
finish() {   # capture the final frame, record failures, exit
    save_shot "$LAST"
    write_failures
    if [ -n "$FAILS" ]; then
        echo "[desktop-test] FAILURES: $FAILS"
        if [ "$SOFT" = "true" ]; then
            echo "[desktop-test] SOFT mode — published; failures recorded for the release body (job not blocked)."
            exit 0
        fi
        exit 1
    fi
    echo "[desktop-test] PASS: 'About This Computer' + menu bar present — wrote $SHOT (the published screenshot)"
    exit 0
}
gate_fail() {   # $1 = short label (goes on the screenshot), $2 = detail (log only)
    add_fail "$1"
    echo "[desktop-test] FAIL: $1 — $2"
    [ "$SOFT" = "true" ] || finish   # hard mode: stop at the first failure
}

mkdir -p tests screenshot

# --- 1. desktop rendered: "System Disk" AND "Workspace" -----------------------
echo "[desktop-test] 1/5 waiting for the desktop — 'System Disk' AND 'Workspace' (<= ${DESKTOP_DEADLINE}s)"
END=$(( $(date +%s) + DESKTOP_DEADLINE )); i=0; up=0; text=""; corner=""; f=""
while [ "$(date +%s)" -lt "$END" ]; do
    i=$((i + 1)); f="tests/desk-$(printf '%03d' "$i").ppm"; dump "$f"
    [ -s "$f" ] || { sleep 3; continue; }
    text=$(ocr "$f"); corner=$(ocr_corner "$f"); d=0; w=0
    # "Workspace" is menu-bar text -> full-frame OCR; "System Disk" is the small
    # top-right icon label -> corner OCR (full frame can't read it).
    { has 'System[[:space:]]*Disk' "$corner" || has 'System[[:space:]]*Disk' "$text"; } && d=1
    has 'Workspace' "$text" && w=1
    echo "[desktop-test]   frame $i: System Disk=$d Workspace=$w"
    { [ "$d" -eq 1 ] && [ "$w" -eq 1 ]; } && { up=1; break; }
    # If the greeter's own controls are still on screen, the first login attempt
    # didn't take — re-submit admin. Guarded on greeter text so it NEVER fires on
    # a desktop that's merely still rendering (that shows no such labels).
    if has 'Log[[:space:]]*In|Shut[[:space:]]*Down|Username|Restart' "$text"; then
        echo "[desktop-test]   greeter still up — re-attempting admin login"
        relogin
    fi
    sleep 3
done
LAST="$f"
if [ "$up" -ne 1 ]; then
    echo "[desktop-test]   full-frame OCR:"; printf '%s\n' "${text:-<none>}" | sed 's/^/[ocr] /'
    echo "[desktop-test]   corner OCR:";     printf '%s\n' "${corner:-<none>}" | sed 's/^/[ocr-ne] /'
    gate_fail "desktop not rendered" "'System Disk'+'Workspace' not both OCR'd within ${DESKTOP_DEADLINE}s"
else
    echo "[desktop-test] 1/5 PASS: desktop is up"
fi

# --- 2. discover the Command modifier via the Run… dialog ---------------------
# Run… uses NSCommandKeyMask|NSShiftKeyMask + "R" (confirmed in Workspace.m), so
# the chord is Cmd+SHIFT+R. Probe each candidate Command modifier WITH shift.
echo "[desktop-test] 2/5 probing Command modifier (Cmd+Shift+R must open the Run… dialog)"
MOD=""; RUN_KEYS=""
for cand in $MODS; do
    key esc; key esc
    combo="${cand}-shift-r"
    mon "sendkey $combo"; sleep 1.2
    f="tests/run-${cand}.ppm"; dump "$f"
    t=$(ocr "$f")
    if has 'command to execute|Type the command' "$t"; then
        MOD="$cand"; RUN_KEYS="$combo"
        echo "[desktop-test]   Command modifier = '$cand' — '$combo' opened the Run… dialog"; key esc; break
    fi
    echo "[desktop-test]   '$combo' did not open Run… (OCR: $(printf '%s' "$t" | tr '\n' ' ' | grep -oiE 'run|cancel|command' | tr '\n' ',' | sed 's/,$//'))"
done
if [ -z "$MOD" ]; then
    echo "[desktop-test]   -> the QEMU keyname for GNUstep's Command modifier is wrong (see run-*.ppm in boot-artifacts),"
    echo "[desktop-test]      or the Run… detection missed the dialog. Set GATE_CMD_MODS and re-run."
    gate_fail "Command modifier not found" "no modifier opened the Run… dialog (tried: $MODS)"
fi

# --- 3 & 4. close windows, then open About This Computer (needs the modifier) --
if [ -n "$MOD" ]; then
    echo "[desktop-test] 3/5 closing open windows (Cmd+W x5)"
    n=0; while [ "$n" -lt 5 ]; do mon "sendkey ${MOD}-w"; sleep 0.4; n=$((n + 1)); done

    echo "[desktop-test] 4/5 opening About This Computer ($RUN_KEYS -> '$CMD')"
    key esc
    mon "sendkey $RUN_KEYS"; sleep 1
    type_str "$CMD"
    key ret
    park   # get the mouse pointer out of the About window before we capture the frame
fi

# --- 5. About This Computer up AND the menu bar STILL present -----------------
# Require BOTH "About This Computer" and "Workspace" in the SAME (final) frame.
# "Workspace" was checked in step 1, but the menu bar can crash/vanish between
# then and the capture (gershwin-desktop/gershwin-components#98) — we must never
# publish a menu-less screenshot, and a menu that dies after login must fail here.
about=0; menu=0
if [ -n "$MOD" ]; then
    echo "[desktop-test] 5/5 verifying 'About This Computer' + menu bar ('Workspace') (<= ${ABOUT_DEADLINE}s)"
    END=$(( $(date +%s) + ABOUT_DEADLINE )); i=0
    while [ "$(date +%s)" -lt "$END" ]; do
        i=$((i + 1)); f="tests/about-$(printf '%03d' "$i").ppm"; dump "$f"
        [ -s "$f" ] || { sleep 2; continue; }
        LAST="$f"; text=$(ocr "$f"); about=0; menu=0
        has 'About[[:space:]]*This[[:space:]]*Computer' "$text" && about=1
        has 'Workspace' "$text" && menu=1
        echo "[desktop-test]   frame $i: About=$about Menu(Workspace)=$menu"
        { [ "$about" -eq 1 ] && [ "$menu" -eq 1 ]; } && break
        sleep 2
    done
fi

# --- 6. record any About/menu failure, then capture + (soft) annotate + exit --
if [ "$about" -eq 1 ] && [ "$menu" -ne 1 ]; then
    echo "[desktop-test]   About is up but the 'Workspace' menu is gone (crashed after step 1) — see gershwin-components#98."
    gate_fail "menu bar missing" "About up but Workspace menu absent at capture (#98)"
elif [ "$about" -ne 1 ]; then
    if [ -n "$MOD" ]; then
        echo "[desktop-test]   Run… opened but no About window — Workspace may need -d (to vend uitest's DO), or uitest not on PATH."
        gate_fail "About window absent" "uitest ran but produced no About window"
    else
        gate_fail "About window absent" "skipped — no Command modifier"
    fi
fi
finish
