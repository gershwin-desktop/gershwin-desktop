#!/bin/sh
set -e

# === Configuration ===
DIST="excalibur"
MIRROR="http://deb.devuan.org/merged"
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    x86_64|i?86) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $HOST_ARCH"; exit 1 ;;
esac
WORK="$(pwd)/work"
# Canonical cross-flavor name: gershwin-on-<flavor>[-<channel>]-<UTC stamp>-<arch>.iso
CHANNEL="${CHANNEL:-}"   # release channel (rc/dev) infixed into the ISO name when set
ISO_NAME="gershwin-on-devuan-${CHANNEL:+${CHANNEL}-}$(date -u +%Y%m%d%H%M%S)-${HOST_ARCH}.iso"

# gershwin-developer clone ref (default main) + the source-repo branch passed to
# checkout.sh (empty = default). The dev workflow sets these for the dev channel;
# unset = rc/default behaviour. See gershwin-developer's checkout.sh.
GERSHWIN_REF="${GERSHWIN_REF:-main}"
GERSHWIN_BRANCH="${GERSHWIN_BRANCH:-}"

# === Clean previous build ===
rm -rf "${WORK}"
mkdir -p "${WORK}"

# === Step 1: Bootstrap minimal Devuan root filesystem ===
# Runs inside the Devuan build container (ci/containers/Dockerfile), which has
# Devuan's debootstrap (with the excalibur script) + devuan-keyring, so this
# works natively — no cross-distro workarounds needed.
echo "==> Bootstrapping ${DIST} root filesystem..."
debootstrap --arch="${ARCH}" --variant=minbase "${DIST}" "${WORK}/rootfs" "${MIRROR}"

# === Step 2: Configure apt sources inside rootfs ===
cat > "${WORK}/rootfs/etc/apt/sources.list" << EOF
deb ${MIRROR} ${DIST} main contrib non-free non-free-firmware
deb ${MIRROR} ${DIST}-security main contrib non-free non-free-firmware
deb ${MIRROR} ${DIST}-updates main contrib non-free non-free-firmware
deb ${MIRROR} ${DIST}-backports main contrib non-free non-free-firmware
EOF

# === Step 2b: Prepare chroot ===
echo "==> Preparing chroot..."
mount --bind /dev "${WORK}/rootfs/dev"
mount --bind /dev/pts "${WORK}/rootfs/dev/pts"
mount -t proc proc "${WORK}/rootfs/proc"
mount -t sysfs sysfs "${WORK}/rootfs/sys"

# Prevent services from starting during install
cat > "${WORK}/rootfs/usr/sbin/policy-rc.d" << 'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "${WORK}/rootfs/usr/sbin/policy-rc.d"

# === Step 3: Install packages ===
echo "==> Installing packages..."

# Uncomment arch-specific lines, then strip remaining comments
cp packages.list packages.list.tmp
sed -i "s/^#${HOST_ARCH} //g" packages.list.tmp
PACKAGES=$(grep -v '^#' packages.list.tmp | grep -v '^$' | tr '\n' ' ')
rm -f packages.list.tmp

chroot "${WORK}/rootfs" /bin/sh -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ${PACKAGES}
    apt-get clean
    rm -rf /var/lib/apt/lists/*
"

# === Step 3b: Install Gershwin ===
echo "==> Installing Gershwin..."

chroot "${WORK}/rootfs" /bin/sh -c "
    git clone -b \"${GERSHWIN_REF}\" https://github.com/gershwin-desktop/gershwin-developer.git /Developer
    /Developer/Library/Scripts/bootstrap.sh
    BRANCH=\"${GERSHWIN_BRANCH}\" /Developer/Library/Scripts/checkout.sh
    cd /Developer && make install
"

# Enable Gershwin services for sysvinit
chroot "${WORK}/rootfs" update-rc.d dshelper defaults 

# Enable dns-sd browsing
chroot "${WORK}/rootfs" update-rc.d avahi-daemon defaults

# Enable sshd
chroot "${WORK}/rootfs" update-rc.d ssh defaults

# Enable boot splash
# chroot "${WORK}/rootfs" update-rc.d plymouth defaults

# Configure boot splash theme
# chroot "${WORK}/rootfs" plymouth-set-default-theme -R spinner

# Configure inittab for LoginWindow (respawn at runlevel 5)
sed -i.bak -E 's/^id:[0-9]+:initdefault:/id:5:initdefault:/' "${WORK}/rootfs/etc/inittab"
grep -q '^lw:5:respawn:/System/Library/Scripts/LoginWindow.sh' "${WORK}/rootfs/etc/inittab" || \
    echo 'lw:5:respawn:/System/Library/Scripts/LoginWindow.sh' >> "${WORK}/rootfs/etc/inittab"

# Initialize directory services database
chroot "${WORK}/rootfs" /System/Library/Tools/dscli init

# Allow password authentication and empty password for sshd
chroot "${WORK}/rootfs" sed -i 's/^[[:space:]#]*PasswordAuthentication[[:space:]]*.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
chroot "${WORK}/rootfs" sed -i 's/^[[:space:]#]*PermitEmptyPasswords[[:space:]]*.*/PermitEmptyPasswords yes/' /etc/ssh/sshd_config

# Disable PC speaker beeps
echo "blacklist pcspkr" | tee "${WORK}/rootfs"/etc/modprobe.d/blacklist-pcspkr.conf

# Software-present fallback for virtio-gpu (UTM/QEMU).
# The guest's virtio-gpu exposes no virgl, so the only GL is llvmpipe. The
# modesetting driver refuses glamor on llvmpipe and then leaves ShadowFB off,
# so nothing is ever flushed to the scanout -> black screen once X starts.
# Force the software-present path. Scoped via MatchDriver so it ONLY touches
# virtio_gpu -- real Intel/AMD/NVIDIA GPUs keep hardware acceleration.
mkdir -p "${WORK}/rootfs"/etc/X11/xorg.conf.d
cat > "${WORK}/rootfs"/etc/X11/xorg.conf.d/20-virtio-gpu.conf <<\EOF
Section "OutputClass"
    Identifier  "virtio-gpu software present"
    MatchDriver "virtio_gpu"
    Driver      "modesetting"
    Option      "AccelMethod" "none"
    Option      "ShadowFB"    "true"
EndSection
EOF

# Configure LoginWindow for auto-login
mkdir -p "${WORK}/rootfs"/Local/Library/Preferences
cat > "${WORK}/rootfs"/Local/Library/Preferences/LoginWindow.plist <<\EOF
{
    lastLoggedInUser = admin;
    lastSession = "/System/Library/Scripts/Gershwin.sh";
}
EOF

# === Final cleanup ===
chroot "${WORK}/rootfs" /bin/sh -c "
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    rm -rf /tmp/* /var/tmp/*
"
rm -f "${WORK}/rootfs/usr/sbin/policy-rc.d"

umount "${WORK}/rootfs/sys" 2>/dev/null || true
umount "${WORK}/rootfs/proc" 2>/dev/null || true
umount "${WORK}/rootfs/dev/pts" 2>/dev/null || true
umount "${WORK}/rootfs/dev" 2>/dev/null || true

# === Step 4: Create squashfs ===
echo "==> Creating squashfs..."
mkdir -p "${WORK}/iso/live"
cp "${WORK}/rootfs/boot/vmlinuz-"* "${WORK}/iso/live/vmlinuz"
cp "${WORK}/rootfs/boot/initrd.img-"* "${WORK}/iso/live/initrd.img"
mksquashfs "${WORK}/rootfs" "${WORK}/iso/live/filesystem.squashfs" \
    -comp xz -e boot/vmlinuz-* -e boot/initrd.img-*

# === Step 5: Setup GRUB ===
echo "==> Setting up GRUB..."
mkdir -p "${WORK}/iso/boot/grub"
cp grub.cfg "${WORK}/iso/boot/grub/grub.cfg"

if [ "$ARCH" = "amd64" ]; then
    # --- x86_64: BIOS + UEFI hybrid ---
    grub-mkstandalone \
        --format=i386-pc \
        --output="${WORK}/bios.img" \
        --install-modules="linux normal iso9660 biosdisk memdisk search tar ls all_video font gfxterm part_gpt part_msdos" \
        --modules="linux normal iso9660 biosdisk search part_gpt part_msdos" \
        --locales="" --fonts="" \
        "boot/grub/grub.cfg=${WORK}/iso/boot/grub/grub.cfg"

    cat /usr/lib/grub/i386-pc/cdboot.img "${WORK}/bios.img" > "${WORK}/iso/boot/grub/bios.img"

    grub-mkstandalone \
        --format=x86_64-efi \
        --output="${WORK}/bootx64.efi" \
        --install-modules="linux normal iso9660 search tar ls all_video font gfxterm part_gpt part_msdos fat efi_gop efi_uga" \
        --modules="linux normal iso9660 search part_gpt part_msdos fat efi_gop" \
        --locales="" --fonts="" \
        "boot/grub/grub.cfg=${WORK}/iso/boot/grub/grub.cfg"

    mkdir -p "${WORK}/iso/EFI/boot"
    cp "${WORK}/bootx64.efi" "${WORK}/iso/EFI/boot/bootx64.efi"

    dd if=/dev/zero of="${WORK}/iso/boot/grub/efi.img" bs=1M count=4 2>/dev/null
    mkfs.vfat "${WORK}/iso/boot/grub/efi.img"
    mmd -i "${WORK}/iso/boot/grub/efi.img" EFI EFI/boot
    mcopy -i "${WORK}/iso/boot/grub/efi.img" "${WORK}/bootx64.efi" ::EFI/boot/bootx64.efi

    echo "==> Building ISO (BIOS+UEFI)..."
    xorriso -as mkisofs \
        -R -J -joliet-long \
        -V "GERSHWIN" \
        -partition_offset 16 \
        -b boot/grub/bios.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --grub2-boot-info \
            --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
            -no-emul-boot \
        -append_partition 2 0xef "${WORK}/iso/boot/grub/efi.img" \
        -appended_part_as_gpt \
        -o "${ISO_NAME}" \
        "${WORK}/iso"

elif [ "$ARCH" = "arm64" ]; then
    # --- ARM64: UEFI only ---
    grub-mkstandalone \
        --format=arm64-efi \
        --output="${WORK}/bootaa64.efi" \
        --install-modules="linux normal iso9660 search tar ls all_video font gfxterm part_gpt part_msdos fat efi_gop" \
        --modules="linux normal iso9660 search part_gpt part_msdos fat efi_gop" \
        --locales="" --fonts="" \
        "boot/grub/grub.cfg=${WORK}/iso/boot/grub/grub.cfg"

    mkdir -p "${WORK}/iso/EFI/boot"
    cp "${WORK}/bootaa64.efi" "${WORK}/iso/EFI/boot/bootaa64.efi"

    dd if=/dev/zero of="${WORK}/iso/boot/grub/efi.img" bs=1M count=4 2>/dev/null
    mkfs.vfat "${WORK}/iso/boot/grub/efi.img"
    mmd -i "${WORK}/iso/boot/grub/efi.img" EFI EFI/boot
    mcopy -i "${WORK}/iso/boot/grub/efi.img" "${WORK}/bootaa64.efi" ::EFI/boot/bootaa64.efi

    echo "==> Building ISO (UEFI only)..."
    xorriso -as mkisofs \
        -R -J -joliet-long \
        -V "GERSHWIN" \
        -e boot/grub/efi.img \
            -no-emul-boot \
        -append_partition 2 0xef "${WORK}/iso/boot/grub/efi.img" \
        -appended_part_as_gpt \
        -o "${ISO_NAME}" \
        "${WORK}/iso"
fi

echo "==> Done: ${ISO_NAME}"
ls -lh "${ISO_NAME}"
