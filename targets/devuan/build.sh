#!/bin/sh
set -e

# === Configuration ===
DIST="excalibur"
MIRROR="http://deb.devuan.org/merged"
# XLibre repo coordinates. The component tracks DIST: Devuan stable (excalibur)
# -> "stable", Devuan testing (freia) -> "testing". Keep in sync when DIST moves.
XLIBRE_URI="https://xlibre-debian.github.io/devuan/"
XLIBRE_COMPONENT="stable"
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

# Seed the trust store first. The XLibre repo is HTTPS-only, but a minbase
# debootstrap has no CA bundle, so apt cannot verify github.io and drops the
# repo. It does that as a *warning*, not an error -- the build then runs on with
# every xlibre package "Unable to locate". Devuan's own mirror is plain http, so
# ca-certificates installs fine before the XLibre repo is ever added.
# -e so a failure here stops the build instead of surfacing much later.
chroot "${WORK}/rootfs" /bin/sh -ec "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates
"

# === Step 3a: Configure the XLibre apt repo inside rootfs ===
# Gershwin ships XLibre instead of Xorg, which lives in a third-party repo, so
# its signing key must be trusted before the package install below. This has to
# come after ca-certificates above -- see the note there.
#
# The key is committed at keys/xlibre.asc rather than fetched at build time, so
# builds are reproducible and keep working when the upstream key host is
# unreachable. apt reads an ASCII-armored key directly from Signed-By, so no
# gpg --dearmor step is needed.
#
# Provenance -- re-verify with these before ever replacing keys/xlibre.asc:
#   source      https://mrchicken.nexussfan.cz/publickey.asc
#   uid         NexusSfan <nexussfan@duck.com>  (rsa4096)
#   fingerprint 2207 5A91 9DAE B177 E874  C5D1 D79C D6F1 B523 94FA
#   confirmed   good signature on dists/main/InRelease of both
#               xlibre-debian.github.io/devuan and .../debian
#
# It is installed as xlibre.asc, NOT as NexusSfan.pgp: that path is owned by
# nexussfan-archive-keyring (pulled in by xlibre-archive-keyring in
# packages.list) and a hand-placed file there would make dpkg file-conflict.
echo "==> Configuring XLibre repository..."
install -D -m 0644 keys/xlibre.asc "${WORK}/rootfs/usr/share/keyrings/xlibre.asc"

mkdir -p "${WORK}/rootfs/etc/apt/sources.list.d"
cat > "${WORK}/rootfs/etc/apt/sources.list.d/xlibre.sources" << EOF
Types: deb
URIs: ${XLIBRE_URI}
Suites: main
Components: ${XLIBRE_COMPONENT}
Architectures: ${ARCH}
Signed-By: /usr/share/keyrings/xlibre.asc
EOF

# XLibre's upstream instructions say Excalibur users "HAVE to enable backports",
# because xserver-xlibre-video-amdgpu needs mesa >= 25.2.6 and excalibur ships
# 25.0.7. Enabling backports is necessary but NOT sufficient: it is NotAutomatic
# (priority 100), so apt refuses to take mesa from it to satisfy a dependency
# once a stable mesa is already selected, and the build dies with
# "xserver-xlibre-video-amdgpu : Depends: mesa-common-dev (>= 25.2.6) but
# 25.0.7-2+deb13u1 is to be installed". This pin raises the mesa stack above
# stable (500) so apt actually uses the backport.
#
# Pinned by explicit name, not a glob, and scoped to exactly the src:mesa
# binaries this image actually installs -- all seven of which backports ships at
# a consistent 26.1.2.
#
# Deliberately NOT pinned: mesa-va-drivers and mesa-vdpau-drivers. Backports is
# internally inconsistent right now -- those two are still at 25.2.6 and carry a
# strict "mesa-libgallium (= 25.2.6-1~bpo13+1)" dep that backports can no longer
# satisfy, since mesa-libgallium has moved to 26.1.2. Neither is in this image,
# so pinning them would be inert today but would strand the build the moment
# anything pulled in hardware video acceleration. Same reasoning excludes
# mesa-opencl-icd and mesa-drm-shim.
#
# Kept in the shipped ISO on purpose: the installed system must keep tracking
# backports mesa for XLibre's sake instead of drifting back to stable.
mkdir -p "${WORK}/rootfs/etc/apt/preferences.d"
cat > "${WORK}/rootfs/etc/apt/preferences.d/xlibre-mesa-backports.pref" << EOF
Package: libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-common-dev mesa-libgallium mesa-vulkan-drivers
Pin: release n=${DIST}-backports
Pin-Priority: 600
EOF

# -e so an unresolvable package list fails the build here. Without it a failed
# apt-get install is swallowed by the inner shell and only shows up much later
# as a confusing error from the Gershwin step.
chroot "${WORK}/rootfs" /bin/sh -ec "
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
# Plymouth is now handled by install-plymouth.sh in gershwin-system
# (invoked from SystemPrepare.sh); these were the old manual steps:
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
# Still correct under XLibre: xserver-xlibre-core Provides and Replaces
# xserver-xorg-video-modesetting, and xserver-xlibre-common still owns
# /etc/X11/xorg.conf.d, so both the driver name and this path are unchanged.
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
