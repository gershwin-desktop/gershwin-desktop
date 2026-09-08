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

# Record for a fixed window rather than matching on a success marker: this is a
# diagnostic, and a boot that never reaches a desktop has no marker to match.
# Anything the kernel, kextd, launchd or X says lands in the log.
set timeout $BOOT_WINDOW
expect {
    timeout { puts "\n==> recording window closed (${BOOT_WINDOW}s)" }
    eof     { puts "\n==> guest exited" }
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
grep -aiE "drm|vgapci|bochs|kms|Xorg|LoginWindow" "$LOG" 2>/dev/null | head -40 || true
exit 0
