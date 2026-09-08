#!/bin/sh
# verbose-boot.sh — boot the nextbsd ISO with the kernel console UNMUTED and
# keep the whole transcript.
#
# WHY
#
# The screenshot gate can tell us the VM never reached a graphical screen, and
# nothing else. Its serial log stops at
#
#	-- Muting boot messages --
#
# because the shipped image sets boot_mutemsgs="YES" (nextbsd#363), so every
# kext attach, DRM probe and launchd message after early init is invisible. A
# dev ISO that boots to a text console instead of a desktop therefore produces
# no evidence about why.
#
# RB_VERBOSE bypasses that mute in the kernel, which is exactly what
# nextbsd/nextbsd's tests/iso-boot-test.sh already relies on. This runs the same
# handshake: interrupt the loader over serial, point the console at the UART,
# then `boot -v`. Shipped images stay quiet; CI sees everything.
#
# DIAGNOSTIC ONLY. It never gates anything -- the caller runs it with
# continue-on-error, and it exits 0 even when the guest ignores it. Its output
# is a log to read, not a verdict.
set -eu

ISO=${1:?usage: verbose-boot.sh path/to/*.iso}
[ -f "$ISO" ] || { echo "ERROR: $ISO not found" >&2; exit 1; }

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${OUT:-tests}
mkdir -p "$OUT"
LOG="$OUT/verbose-boot.log"
EXP="$OUT/verbose-boot.exp"
: > "$LOG"

OVMF=/usr/share/ovmf/OVMF.fd
[ -f "$OVMF" ] || OVMF=/usr/share/OVMF/OVMF_CODE.fd
ACCEL="-accel tcg -cpu qemu64"
if [ -e /dev/kvm ]; then sudo chmod 666 /dev/kvm 2>/dev/null || true; fi
[ -r /dev/kvm ] && [ -w /dev/kvm ] && ACCEL="-accel kvm -cpu host"

echo "==> verbose boot: $ISO (accel=$ACCEL, ovmf=$OVMF)"

# How long to keep recording after the kernel starts. The desktop either
# appears well inside this or the log shows why it did not.
BOOT_WINDOW=${BOOT_WINDOW:-420}

cat > "$EXP" <<EXPEOF
set timeout 600
log_file -a $LOG
log_user 1

spawn qemu-system-x86_64 \\
    -machine q35 -m 4G -smp 2 $ACCEL -bios $OVMF \\
    -cdrom $ISO -boot d \\
    -vga std -nic user,model=e1000 \\
    -display none -serial stdio -no-reboot

source $HERE/loader.exp.inc

# Route the console at the UART and unmute. boot_multicons keeps the VGA
# console alive too, so the framebuffer still behaves as it normally would --
# this changes what we can SEE, not how the image boots.
loader_prompt 120
loader_set "set console=comconsole"
loader_set "set boot_serial=YES"
loader_set "set comconsole_speed=115200"
loader_set "set boot_multicons=YES"
loader_boot "boot -v"

# Record, watching for a console login prompt as we go.
#
# The transcript alone stops being useful shortly after this point: launchd's
# early-init does "console quiet", and once vt hands the console to drmfb the
# remaining output follows the framebuffer rather than the UART. Everything
# userland says about a failing X session is on the far side of that.
#
# So if a login prompt reaches the serial console, take it and read the logs out
# of the guest directly. If it never arrives, keep recording and say so -- the
# kernel half of the transcript is still worth having on its own.
set got_login 0
set timeout $BOOT_WINDOW
expect {
    -re {login: *$}   { set got_login 1 }
    -re {(#|\\\$) $} { set got_login 2 }
    timeout           { puts "\n==> recording window closed (${BOOT_WINDOW}s), no console login seen" }
    eof               { puts "\n==> guest exited" }
}

if {\$got_login == 1} {
    puts "\n==> console login prompt reached — pulling logs from inside the guest"
    # root first: on the live ISO it needs no password and, unlike admin, does
    # not depend on DirectoryServices -- which is one of the things that might
    # be broken. admin exists only in DS (dscli init, uid 5000, no password),
    # so falling back to it also tells us whether DS auth works at all.
    set timeout 30
    send -s "root\r"
    expect {
        -re {[Pp]assword: *$} { send -s "\r" }
        -re {(#|\\\$) $}     { set got_login 2 }
        -re {login: *$} {
            puts "\n==> root refused; trying admin (this also tests DS auth)"
            send -s "admin\r"
            expect -re {[Pp]assword: *$} { send -s "\r" } timeout { }
        }
        timeout { }
    }
    expect {
        -re {(#|\\\$) $} { set got_login 2 }
        timeout           { puts "\n==> no shell after login" }
    }
}

if {\$got_login == 2} {
    puts "\n==> shell — dumping the state that explains a missing desktop"
    set timeout 60
    # Markers so the interesting part is greppable in a 1500-line transcript.
    foreach cmd {
        "echo '===== GATE-DIAG BEGIN ====='"
        "ls -la /dev/dri/ 2>&1"
        "kextstat 2>/dev/null | head -20"
        "launchctl list 2>/dev/null | grep -iE 'loginwindow|dshelper|gdomap|dbus' || echo 'NO gershwin daemons listed'"
        "ps ax | grep -E '[X]org|[L]oginWindow' || echo 'NO Xorg/LoginWindow process'"
        "echo '----- Xorg.0.log (errors) -----'"
        "grep -aiE '\\(EE\\)|no screens|Fatal|Backtrace' /var/log/Xorg.0.log 2>/dev/null || echo 'NO /var/log/Xorg.0.log or no errors in it'"
        "echo '----- Xorg.0.log (tail) -----'"
        "tail -n 120 /var/log/Xorg.0.log 2>/dev/null || echo 'NO /var/log/Xorg.0.log'"
        "echo '----- system.log (tail) -----'"
        "tail -n 60 /var/log/system.log 2>/dev/null || echo 'no system.log'"
        "echo '===== GATE-DIAG END ====='"
    } {
        send -s "\$cmd\r"
        expect -re {(#|\\\$) $} { } timeout { puts "\n==> timed out on: \$cmd" }
    }
}
exit 0
EXPEOF

expect -f "$EXP" || echo "==> expect exited non-zero (diagnostic only, continuing)"

echo "==> transcript: $LOG ($(wc -l < "$LOG" 2>/dev/null || echo 0) lines)"
echo "==> did the mute get bypassed?"
if grep -aq "Muting boot messages" "$LOG" 2>/dev/null; then
    echo "    NO -- console still muted; the loader handshake did not take"
else
    echo "    yes -- no mute marker in the transcript"
fi
echo "==> graphics/DRM lines, if any:"
grep -aiE "drm|vgapci|bochs|kms" "$LOG" 2>/dev/null | head -25 || true
echo "==> in-guest diagnostics (the part that explains a missing desktop):"
if grep -aq "GATE-DIAG BEGIN" "$LOG" 2>/dev/null; then
    sed -n '/GATE-DIAG BEGIN/,/GATE-DIAG END/p' "$LOG" 2>/dev/null | head -200
else
    echo "    not captured -- no console login prompt reached the serial port."
    echo "    The kernel half of the transcript above is still valid; userland"
    echo "    output stops once launchd does 'console quiet' and vt hands the"
    echo "    console to drmfb."
fi
exit 0
