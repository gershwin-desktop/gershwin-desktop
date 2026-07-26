#!/bin/bash
set -euo pipefail

OUTPUT_IMAGE=${1:?Usage: $0 <output-image>}
CHROOT_DIR=${CHROOT_DIR:-chroot}

if [ ! -d "$CHROOT_DIR" ]; then
  echo "Error: chroot directory '$CHROOT_DIR' not found." >&2
  exit 1
fi

if [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "arm64" ]; then
  echo "Error: Raspberry Pi image creation is only supported on arm64/aarch64 builders." >&2
  exit 1
fi

if [ ! -d "$CHROOT_DIR/boot/firmware" ]; then
  echo "Error: missing '$CHROOT_DIR/boot/firmware'. Ensure raspi-firmware is installed in the image." >&2
  exit 1
fi

KERNEL_FILE=$(ls -1 "$CHROOT_DIR"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -n1 || true)
INITRD_FILE=$(ls -1 "$CHROOT_DIR"/boot/initrd.img-* 2>/dev/null | sort -V | tail -n1 || true)

if [ -z "$KERNEL_FILE" ] || [ -z "$INITRD_FILE" ]; then
  echo "Error: could not detect kernel/initrd in '$CHROOT_DIR/boot'." >&2
  exit 1
fi

# Reserve enough FAT space for firmware, kernel, initramfs and future kernel updates.
BOOT_PARTITION_SIZE_MB=${BOOT_PARTITION_SIZE_MB:-256}
ROOTFS_USED_MB=$(du -sm "$CHROOT_DIR" | awk '{print $1}')
# Keep the initial image small while leaving minimal free space before first-boot expansion.
ROOTFS_SLACK_MB=${ROOTFS_SLACK_MB:-64}
ROOT_PARTITION_SIZE_MB=$((ROOTFS_USED_MB + ROOTFS_SLACK_MB))
# Extra safety margin for GPT metadata and partition alignment.
TOTAL_SIZE_MB=$((BOOT_PARTITION_SIZE_MB + ROOT_PARTITION_SIZE_MB + 32))

truncate -s "${TOTAL_SIZE_MB}M" "$OUTPUT_IMAGE"

parted -s "$OUTPUT_IMAGE" mklabel gpt
parted -s "$OUTPUT_IMAGE" mkpart firmware fat32 1MiB "$((BOOT_PARTITION_SIZE_MB + 1))MiB"
parted -s "$OUTPUT_IMAGE" mkpart rootfs ext4 "$((BOOT_PARTITION_SIZE_MB + 1))MiB" 100%
parted -s "$OUTPUT_IMAGE" set 1 msftdata on

LOOP_DEVICE=
WORKDIR=$(mktemp -d)
cleanup() {
  set +e
  mountpoint -q "$WORKDIR/boot" && umount "$WORKDIR/boot"
  mountpoint -q "$WORKDIR/root" && umount "$WORKDIR/root"
  [ -n "$LOOP_DEVICE" ] && kpartx -dv "$LOOP_DEVICE"
  [ -n "$LOOP_DEVICE" ] && losetup -d "$LOOP_DEVICE"
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Use a plain loop device (no --partscan) and kpartx to create partition
# device-mapper nodes (/dev/mapper/loopXp1 etc.) — this works reliably
# inside Docker containers where udev is not running.
LOOP_DEVICE=$(losetup --show --find "$OUTPUT_IMAGE")
kpartx -av "$LOOP_DEVICE"
LOOP_BASE=$(basename "$LOOP_DEVICE")
BOOT_PART="/dev/mapper/${LOOP_BASE}p1"
ROOT_PART="/dev/mapper/${LOOP_BASE}p2"

mkfs.vfat -F32 -n FIRMWARE "$BOOT_PART"
mkfs.ext4 -F -L rootfs "$ROOT_PART"

mkdir -p "$WORKDIR/root" "$WORKDIR/boot"
mount "$ROOT_PART" "$WORKDIR/root"
mount "$BOOT_PART" "$WORKDIR/boot"

rsync -aHAX --numeric-ids \
  --exclude='/boot/firmware/*' \
  --exclude='/dev/*' \
  --exclude='/proc/*' \
  --exclude='/sys/*' \
  --exclude='/run/*' \
  --exclude='/tmp/*' \
  "$CHROOT_DIR"/ "$WORKDIR/root"/

mkdir -p "$WORKDIR/root/boot/firmware"
rsync -a "$CHROOT_DIR/boot/firmware/" "$WORKDIR/boot/"

KERNEL_BASENAME=$(basename "$KERNEL_FILE")
INITRD_BASENAME=$(basename "$INITRD_FILE")

if [ ! -f "$WORKDIR/boot/$KERNEL_BASENAME" ]; then
  cp "$KERNEL_FILE" "$WORKDIR/boot/$KERNEL_BASENAME"
fi
if [ ! -f "$WORKDIR/boot/$INITRD_BASENAME" ]; then
  cp "$INITRD_FILE" "$WORKDIR/boot/$INITRD_BASENAME"
fi

FSTAB_PATH="$WORKDIR/root/etc/fstab"
EXTRA_FSTAB=$(mktemp)
if [ -f "$FSTAB_PATH" ]; then
  awk '$2 != "/" && $2 != "/boot/firmware" {print}' "$FSTAB_PATH" > "$EXTRA_FSTAB"
fi
cat > "$FSTAB_PATH" <<'FSTAB'
LABEL=rootfs / ext4 defaults,noatime 0 1
LABEL=FIRMWARE /boot/firmware vfat defaults 0 2
FSTAB
if [ -s "$EXTRA_FSTAB" ]; then
  cat "$EXTRA_FSTAB" >> "$FSTAB_PATH"
fi
rm -f "$EXTRA_FSTAB"

cat > "$WORKDIR/boot/cmdline.txt" <<'CMDLINE'
console=serial0,115200 console=tty1 root=LABEL=rootfs rootfstype=ext4 fsck.repair=yes rootwait rw quiet splash
CMDLINE

cat > "$WORKDIR/boot/config.txt" <<EOF_CFG
arm_64bit=1
enable_uart=1
kernel=$KERNEL_BASENAME
initramfs $INITRD_BASENAME followkernel
EOF_CFG

sync

echo "Created Raspberry Pi image: $OUTPUT_IMAGE"

# Zip the image to reduce upload size (raw ext4 compresses well).
zip "${OUTPUT_IMAGE}.zip" "$OUTPUT_IMAGE"
rm -f "$OUTPUT_IMAGE"
echo "Zipped image: ${OUTPUT_IMAGE}.zip"
