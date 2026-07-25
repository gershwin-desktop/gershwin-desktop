#!/usr/bin/env sh
#
#
# Gershwin-on-FreeBSD Build Script
#
# This script builds the Gershwin Desktop live system based on FreeBSD.
# It handles workspace preparation, base system installation, desktop
# software integration, and ISO image generation.
#
# Requirements: FreeBSD system with pkg, makefs, mkuzip, etc.

set -e -u

# --- Configuration ---
LABEL="FREEBSD"
IMAGE_NAME_PREFIX="gershwin-on-freebsd"
CHANNEL="${CHANNEL:-}"   # release channel (rc/dev) infixed into the ISO name when set
WORKDIR="/usr/local/freebsd-build"

# gershwin-developer clone ref (default main) and the source-repo branch passed
# to checkout.sh (empty = default branches). The dev workflow sets these to build
# the dev channel; unset = the rc/default behaviour. See gershwin-developer's
# checkout.sh for the per-repo branch fallback.
GERSHWIN_REF="${GERSHWIN_REF:-main}"
GERSHWIN_BRANCH="${GERSHWIN_BRANCH:-}"

# Target Environment (Decoupled from Host)
TARGET_VERSION="${TARGET_VERSION:-14}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"
# Map TARGET_ARCH to filename-friendly architecture string
case "${TARGET_ARCH}" in
    amd64) ARCH_STR="x86_64" ;;
    aarch64) ARCH_STR="aarch64" ;;
    *) ARCH_STR="${TARGET_ARCH}" ;;
esac
TARGET_ABI="FreeBSD:${TARGET_VERSION}:${TARGET_ARCH}"
# Branch and OSVERSION mapping
case "${TARGET_VERSION}" in
    15)
        TARGET_OSVERSION="1500028"
        REPO_BRANCH="latest" # release_1 will contain XLibre; base_quarterly is missing?
        ;;
    16)
        TARGET_OSVERSION="1600000"
        REPO_BRANCH="latest"
        ;;
    *)
        TARGET_OSVERSION="${TARGET_VERSION}00000"
        REPO_BRANCH="${REPO_BRANCH:-stable}"
        ;;
esac

RELEASE_DIR="${WORKDIR}/release"
ISO_DIR="${WORKDIR}/iso"
CD_ROOT="${WORKDIR}/cd_root"
PKGS_STORAGE="${WORKDIR}/packages"
LIVE_USER="freebsd"
PKG_CONF_NAME="FreeBSD"

# Paths to resources
CWD="$(pwd)"
RESOURCE_DIR="${CWD}/resources"
PKG_LIST_DIR="${RESOURCE_DIR}/packages"
CONFIG_DIR="${WORKDIR}/config/repos"
SCRIPTS_DIR="${RESOURCE_DIR}/scripts"
OVERLAYS_DIR="${RESOURCE_DIR}/overlays"

# --- Environment Fixes ---
export ABI="${TARGET_ABI}"
export OSVERSION="${TARGET_OSVERSION}"
export IGNORE_OSVERSION="yes"
export ASSUME_ALWAYS_YES="yes"

# Unified PKG command
pkg_cmd() {
    env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" \
        pkg -R "${CONFIG_DIR}" "$@"
}

# --- Lifecycle Management ---
cleanup() {
    log "Cleaning up mounts..."
    [ -d "${RELEASE_DIR}/dev" ] && umount "${RELEASE_DIR}/dev" 2>/dev/null || true
    [ -d "${RELEASE_DIR}/proc" ] && umount "${RELEASE_DIR}/proc" 2>/dev/null || true
    [ -d "${RELEASE_DIR}/sys" ] && umount "${RELEASE_DIR}/sys" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log_env() {
    log "Environment: ABI=${ABI}, OSVERSION=${OSVERSION}, REPO_BRANCH=${REPO_BRANCH}"
}

# --- Logging ---
log() {
    printf "\033[1;32m%s [BUILD]\033[0m %s\n" "$(date '+%H:%M:%S')" "$*"
}

error() {
    printf "\033[1;31m%s [ERROR]\033[0m %s\n" "$(date '+%H:%M:%S')" "$*" >&2
    exit 1
}

# --- Initialization ---
[ "$(id -u)" -eq 0 ] || error "This script must be run as root."

setup_workspace() {
    log "Preparing workspace at ${WORKDIR}..."

    # Cleanup previous builds
    for dir in "${RELEASE_DIR}" "${CD_ROOT}"; do
        if [ -d "$dir" ]; then
            chflags -R noschg "$dir" >/dev/null 2>&1 || true
            umount -f "${dir}/var/cache/pkg" >/dev/null 2>&1 || true
            umount -f "${dir}/dev" >/dev/null 2>&1 || true
            rm -rf "$dir"
        fi
    done

    mkdir -p "${WORKDIR}" "${ISO_DIR}" "${PKGS_STORAGE}" "${RELEASE_DIR}" "${CD_ROOT}" "${CONFIG_DIR}"

    # Generate Repository Configuration
    log "Generating repository configuration for ${TARGET_ABI} on ${REPO_BRANCH} branch..."
    cat > "${CONFIG_DIR}/FreeBSD.conf" <<EOF
FreeBSD_base: {
  url: "https://pkg.freebsd.org/${TARGET_ABI}/base_${REPO_BRANCH}",
  enabled: yes
}

FreeBSD_pkg: {
  url: "https://pkg.freebsd.org/${TARGET_ABI}/${REPO_BRANCH}",
  enabled: yes
}

FreeBSD_kmods: {
  url: "https://pkg.freebsd.org/${TARGET_ABI}/kmods_${REPO_BRANCH}",
  enabled: yes,
  priority: 10
}
EOF
}

# --- Build Stages ---

install_base_system() {
    log "Installing base system packages..."
    mkdir -p "${RELEASE_DIR}/etc" "${RELEASE_DIR}/var/cache/pkg" "${RELEASE_DIR}/var/db/pkg"
    cp /etc/resolv.conf "${RELEASE_DIR}/etc/resolv.conf"
    # Create missing bzip2.pc file required by freetype2
    mkdir -p "${RELEASE_DIR}/usr/local/libdata/pkgconfig"
    cat > "${RELEASE_DIR}/usr/local/libdata/pkgconfig/bzip2.pc" << 'EOF'
prefix=/usr/local
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: bzip2
Description: bzip2 compression library
Version: 1.0.8
Libs: -L${libdir} -lbz2
Cflags: -I${includedir}
EOF
    
    mount_nullfs "${PKGS_STORAGE}" "${RELEASE_DIR}/var/cache/pkg"
    
    pkg_cmd -r "${RELEASE_DIR}" update -f
    pkg_cmd -r "${RELEASE_DIR}" clean -a -y || true
    
    # Filter base packages to only those available in the repo
    log "Filtering base packages..."
    pkg_cmd -r "${RELEASE_DIR}" rquery -r FreeBSD_base "%n" > "${WORKDIR}/available_base.txt"
    grep -Fxf "${WORKDIR}/available_base.txt" "${PKG_LIST_DIR}/base" > "${WORKDIR}/filtered_base.txt" || true
    
    # Use xargs to avoid "Argument list too long" errors
    log "Installing base packages..."
    if [ -s "${WORKDIR}/filtered_base.txt" ]; then
        cat "${WORKDIR}/filtered_base.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" install -y -r FreeBSD_base
    else
        log "Warning: No base packages found to install!"
    fi
    
    log "Setting vital-base packages..."
    pkg_cmd -r "${RELEASE_DIR}" query "%n" > "${WORKDIR}/installed_pkg.txt"
    grep -Fxf "${WORKDIR}/installed_pkg.txt" "${PKG_LIST_DIR}/vital-base" > "${WORKDIR}/filtered_vital_base.txt" || true
    if [ -s "${WORKDIR}/filtered_vital_base.txt" ]; then
        cat "${WORKDIR}/filtered_vital_base.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" set -y -v 1
    fi
    
    umount "${RELEASE_DIR}/var/cache/pkg"
    rm "${RELEASE_DIR}/etc/resolv.conf"
    touch "${RELEASE_DIR}/etc/fstab"
    mkdir -p "${RELEASE_DIR}/cdrom" "${RELEASE_DIR}/mnt" "${RELEASE_DIR}/media"
}

install_gershwin_software() {
    log "Installing Gershwin software environment..."
    cp /etc/resolv.conf "${RELEASE_DIR}/etc/resolv.conf"
    mkdir -p "${RELEASE_DIR}/var/cache/pkg"
    mount_nullfs "${PKGS_STORAGE}" "${RELEASE_DIR}/var/cache/pkg"
    mount -t devfs devfs "${RELEASE_DIR}/dev"
    mkdir -p "${RELEASE_DIR}/proc"
    mount -t procfs proc "${RELEASE_DIR}/proc"

    pkg_cmd -r "${RELEASE_DIR}" update -f
    pkg_cmd -r "${RELEASE_DIR}" clean -a -y || true
    
    # Filter Gershwin and driver packages
    log "Filtering desktop packages..."
    pkg_cmd -r "${RELEASE_DIR}" rquery -r FreeBSD_pkg "%n" > "${WORKDIR}/available_pkg.txt"
    cat "${PKG_LIST_DIR}/gershwin" "${PKG_LIST_DIR}/drivers" | grep -Fxf "${WORKDIR}/available_pkg.txt" > "${WORKDIR}/filtered_pkg.txt" || true

    # Install main packages from the Pkg repo
    log "Installing Gershwin and driver packages..."
    if [ -s "${WORKDIR}/filtered_pkg.txt" ]; then
        cat "${WORKDIR}/filtered_pkg.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" install -y
    else
        log "Warning: No desktop packages found to install!"
    fi
        
    # Set vital packages
    log "Setting vital-gershwin packages..."
    pkg_cmd -r "${RELEASE_DIR}" query "%n" > "${WORKDIR}/installed_pkg_gershwin.txt"
    grep -Fxf "${WORKDIR}/installed_pkg_gershwin.txt" "${PKG_LIST_DIR}/vital-gershwin" > "${WORKDIR}/filtered_vital_gershwin.txt" || true
    if [ -s "${WORKDIR}/filtered_vital_gershwin.txt" ]; then
        cat "${WORKDIR}/filtered_vital_gershwin.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" set -y -v 1
    fi
    
    # Cleanup
    rm "${RELEASE_DIR}/etc/resolv.conf"
    umount "${RELEASE_DIR}/var/cache/pkg"
    umount "${RELEASE_DIR}/proc" || true
    umount "${RELEASE_DIR}/dev"
}

configure_system() {
    log "Applying system configurations..."

    # Services
    cat <<EFS | xargs -n1 chroot "${RELEASE_DIR}" sysrc
hostname="gershwin"
zfs_enable="YES"
defaultroute_delay="0"
network_interfaces="auto"
ifconfig_DEFAULT="DHCP"
synchronous_dhclient="NO"
dhclient_flags="-n"
ipv6_activate_all_interfaces="YES"
ipv6_cpe_wanif="auto"
rtsold_enable="YES"
background_dhclient="YES"
ntpd_sync_on_start="YES"
ntpd_flags="-g"
kld_list="linux linux64 cuse fusefs hgame"
linux_enable="YES"
devfs_enable="YES"
devfs_system_ruleset="system"
moused_enable="YES"
dbus_enable="YES"
loginwindow_enable="YES"
webcamd_enable="YES"
cupsd_enable="YES"
avahi_daemon_enable="YES"
avahi_dnsconfd_enable="YES"
ntpd_enable="YES"
ntpd_sync_on_start="YES"
clear_tmp_enable="YES"
dsbdriverd_enable="YES"
initgfx_enable="YES"
initgfx_menu="NO"
smartd_enable="YES"
dshelper_enable="YES"
EFS

    # Initialize Directory Services and create live user
    log "Initializing Directory Services..."
    chroot "${RELEASE_DIR}" sh -c ". /System/Library/Makefiles/GNUstep.sh && dscli init"

    # Allow empty password for sshd
    sed -i '' 's/^[[:space:]#]*PermitEmptyPasswords[[:space:]]*.*/PermitEmptyPasswords yes/' /etc/ssh/sshd_config

    # Sudoers
    sed -i "" -e 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' "${RELEASE_DIR}/usr/local/etc/sudoers"

    # System Patches
    [ -f "${CONFIG_DIR}/devfs.rules.extra" ] && cat "${CONFIG_DIR}/devfs.rules.extra" >> "${RELEASE_DIR}/etc/devfs.rules"
    [ -f "${CONFIG_DIR}/fstab.extra" ] && cat "${CONFIG_DIR}/fstab.extra" >> "${RELEASE_DIR}/etc/fstab"
    mkdir -p "${RELEASE_DIR}/compat/linux/dev/shm" "${RELEASE_DIR}/compat/linux/sys"

    # Branding
    mkdir -p "${RELEASE_DIR}/usr/local/share/freebsd"
    echo "gershwin" > "${RELEASE_DIR}/usr/local/share/freebsd/desktop"

    # Update ldconfig cache
    chroot "${RELEASE_DIR}" ldconfig -m /usr/local/lib
}

build_gershwin_components() {
    log "Building Gershwin components from source..."
    git clone --depth 1 -b "${GERSHWIN_REF}" https://github.com/gershwin-desktop/gershwin-developer "${RELEASE_DIR}/Developer"

    cp /etc/resolv.conf "${RELEASE_DIR}/etc/resolv.conf"

    # Pre-build hack for compatibility
    chroot "${RELEASE_DIR}" sh -c "cd /usr/local/lib && rm -f libbfd-2.43.so libbfd-2.44.so && ln -sf libbfd.so libbfd-2.43.so && ln -sf libbfd.so libbfd-2.44.so || true"
    chroot "${RELEASE_DIR}" ldconfig -m /usr/local/lib

    # Make sure we have devfs and procfs for the build
    mount -t devfs devfs "${RELEASE_DIR}/dev" 2>/dev/null || true
    mkdir -p "${RELEASE_DIR}/proc"
    mount -t procfs proc "${RELEASE_DIR}/proc" 2>/dev/null || true

    # Build inside chroot
    chroot "${RELEASE_DIR}" sh -c "/Developer/Library/Scripts/bootstrap.sh"
    chroot "${RELEASE_DIR}" sh -c "PINNED=1 BRANCH=\"${GERSHWIN_BRANCH}\" /Developer/Library/Scripts/checkout.sh"
    chroot "${RELEASE_DIR}" sh -c "cd /Developer && make install"

    # Cleanup mounts
    umount "${RELEASE_DIR}/proc" || true
    umount "${RELEASE_DIR}/dev" || true

    rm -f "${RELEASE_DIR}/etc/resolv.conf"
}

downsize_system() {
    log "Downsizing system (removing heavy build artifacts)..."
    # Reduce LLVM size
    if [ -d "${RELEASE_DIR}/usr/local/llvm19/lib/" ]; then
        mkdir -p "${RELEASE_DIR}/tmp_llvm"
        find "${RELEASE_DIR}/usr/local/llvm19/lib/" -name "libLLVM*.so*" -exec mv {} "${RELEASE_DIR}/tmp_llvm/" \;
        rm -rf "${RELEASE_DIR}/usr/local/llvm19"
        mkdir -p "${RELEASE_DIR}/usr/local/llvm19/lib/"
        mv "${RELEASE_DIR}/tmp_llvm/"* "${RELEASE_DIR}/usr/local/llvm19/lib/"
        rmdir "${RELEASE_DIR}/tmp_llvm"
    fi
}

prepare_boot_env() {
    log "Preparing boot environment..."
    cd "${RELEASE_DIR}" && tar -cf - boot | tar -xf - -C "${CD_ROOT}"
    mkdir -p \
    "${CD_ROOT}/bin" \
    "${CD_ROOT}/compat/linux/dev" \
    "${CD_ROOT}/compat/linux/proc" \
    "${CD_ROOT}/compat/linux/sys" \
    "${CD_ROOT}/Developer" \
    "${CD_ROOT}/dev" \
    "${CD_ROOT}/etc" \
    "${CD_ROOT}/home" \
    "${CD_ROOT}/lib" \
    "${CD_ROOT}/libexec" \
    "${CD_ROOT}/Local" \
    "${CD_ROOT}/media" \
    "${CD_ROOT}/mnt" \
    "${CD_ROOT}/net" \
    "${CD_ROOT}/Network" \
    "${CD_ROOT}/nvidia" \
    "${CD_ROOT}/opt" \
    "${CD_ROOT}/proc" \
    "${CD_ROOT}/rescue" \
    "${CD_ROOT}/root" \
    "${CD_ROOT}/sbin" \
    "${CD_ROOT}/sys" \
    "${CD_ROOT}/System" \
    "${CD_ROOT}/tmp" \
    "${CD_ROOT}/usr" \
    "${CD_ROOT}/uzip" \
    "${CD_ROOT}/var"
    cp "${RELEASE_DIR}"/COPYRIGHT "${CD_ROOT}"/
    chmod +x "${OVERLAYS_DIR}/boot/init_script"
    cp -R "${OVERLAYS_DIR}/boot" "${CD_ROOT}"
    cat "${CD_ROOT}"/boot/loader.conf
    # Remove all modules from the ISO that are not required before the root filesystem is mounted
    # The whole directory /boot/modules is unnecessary
    rm -rf "${CD_ROOT}"/boot/modules/*
    # Remove modules in /boot/kernel that are not loaded at boot time
    find "${CD_ROOT}"/boot/kernel -name '*.ko' \
    -not -name 'cryptodev.ko' \
    -not -name 'firewire.ko' \
    -not -name 'geom_uzip.ko' \
    -not -name 'tmpfs.ko' \
    -not -name 'xz.ko' \
    -delete
    # Compress the kernel
    gzip -f "${CD_ROOT}"/boot/kernel/kernel || true
    rm "${CD_ROOT}"/boot/kernel/kernel || true
    # Compress the modules in a way the kernel understands
    find "${CD_ROOT}"/boot/kernel -type f -name '*.ko' -exec gzip -f {} \;
    find "${CD_ROOT}"/boot/kernel -type f -name '*.ko' -delete
    cp "${RELEASE_DIR}"/etc/login.conf  "${CD_ROOT}"/etc/ # Workaround for: init: login_getclass: unknown class 'daemon'
    tar -cf - rescue | tar -xf - -C "${CD_ROOT}" # /rescue is full of hardlinks
    # Replace identical files with symlinks in rescue
    fdupes -r -S -N "${CD_ROOT}/rescue" || true # -N means do not prompt for confirmation
    ls -lh "${CD_ROOT}/rescue"

    # Comment out splash so that we get the non-color picture built into the kernel instead of a color picture
    # that doesn't match our color scheme
    sed -i '' -e 's|^splash|# splash|g' "${CD_ROOT}"/boot/loader.conf
    
    # Must not try to load tmpfs module in FreeBSD 13 and later, 
    # because it will prevent the one in the kernel from working
    sed -i '' -e 's|^tmpfs_load|# load_tmpfs_load|g' "${CD_ROOT}"/boot/loader.conf
    rm "${CD_ROOT}"/boot/kernel/tmpfs.ko*
    cd -
    
    # https://github.com/freebsd/freebsd-src/blob/5bffa1d2069a05c8346eb34e17a39085fe0bf09b/sbin/init/init.c#L1061
    chmod 755 "${CD_ROOT}/boot/init_script"
}

generate_iso() {
    log "Creating live image (uzip)..."
    # Drop the remote repository catalogues before they get baked in. `pkg clean`
    # above only empties PKG_CACHEDIR (/var/cache/pkg, the downloaded tarballs);
    # the catalogues live under PKG_DBDIR (/var/db/pkg/repos/<repo>/db) and it
    # never touches them. They are pure build residue -- pkg refetches them on
    # the installed system (REPO_AUTOUPDATE defaults to YES, so any install /
    # fetch / search rebuilds them; `pkg update` does it explicitly). Leaving
    # them in cost 3.3 GiB uncompressed / ~446 MiB in the uzip once the upstream
    # `latest` catalogue grew 71 MiB -> 1.66 GiB, and we ship it twice: once as
    # FreeBSD_pkg (our config) and once as FreeBSD-ports (the stock in-image
    # /etc/pkg/FreeBSD.conf). NOTE: local.sqlite -- the installed-package
    # registry -- also lives in PKG_DBDIR and MUST stay; only repos/ goes.
    rm -rf "${RELEASE_DIR}/var/db/pkg/repos"
    # --- ISO SIZE REPORT (exact, uncompressed): every installed package by
    #     flatsize + the biggest directories that ship in the rootfs. This is the
    #     ground truth for what inflates the image (the pkg logs only show
    #     aggregate sizes). Non-fatal; runs on the final RELEASE_DIR pre-makefs.
    echo "=================== ISO SIZE REPORT (freebsd) ==================="
    echo "--- installed packages by flatsize (MiB, top 40) ---"
    chroot "${RELEASE_DIR}" pkg query '%sb %n-%v' 2>/dev/null \
      | sort -rn | awk '{printf "  %9.1f  %s\n", $1/1048576, $2}' | head -40 || true
    echo "--- total installed (all packages, MiB) ---"
    chroot "${RELEASE_DIR}" pkg query '%sb' 2>/dev/null \
      | awk '{s+=$1} END{printf "  %9.1f  (n=%d packages)\n", s/1048576, NR}' || true
    echo "--- biggest directories in the rootfs (MiB, top 30) ---"
    du -sm "${RELEASE_DIR}"/usr/local/* "${RELEASE_DIR}"/Developer \
           "${RELEASE_DIR}"/System "${RELEASE_DIR}"/usr/lib "${RELEASE_DIR}"/boot 2>/dev/null \
      | sort -rn | head -30 || true
    echo "--- inside /usr/local/share (MiB, top 20) ---"
    du -sm "${RELEASE_DIR}"/usr/local/share/* 2>/dev/null | sort -rn | head -20 || true
    echo "--- inside /usr/local/lib (MiB, top 20) ---"
    du -sm "${RELEASE_DIR}"/usr/local/lib/* 2>/dev/null | sort -rn | head -20 || true
    echo "--- rootfs total (MiB) ---"; du -sm "${RELEASE_DIR}" 2>/dev/null || true
    echo "================================================================"
    ( cd "${RELEASE_DIR}" ; makefs -b 75% -f 75% -R 262144 "${CD_ROOT}/rootfs.ufs" . )
    mkdir -p "${CD_ROOT}/boot"
    mkuzip -A zstd -C 12 -d -o "${CD_ROOT}/boot/rootfs.uzip" "${CD_ROOT}/rootfs.ufs"
    rm -f "${CD_ROOT}/rootfs.ufs"

    log "Generating final ISO image..."
    ISO_PATH="${ISO_DIR}/${IMAGE_NAME_PREFIX}-${CHANNEL:+${CHANNEL}-}$(date +%Y%m%d%H%M%S)-${ARCH_STR}.iso"
    # Provide a way to know from the booted ISO what ISO it is
    echo "${IMAGE_NAME_PREFIX}-${CHANNEL:+${CHANNEL}-}$(date +%Y%m%d%H%M%S)-${ARCH_STR}.iso" >> "${CD_ROOT}/.iso"

    # Canonical path: run the upstream mkisoimages.sh from its directory so it can
    # reliably source install-boot.sh and produce a hybrid EFI/BIOS image.
    if [ ! -f "${CWD}/resources/scripts/mkisoimages.sh" ]; then
        error "Required script missing: ${CWD}/resources/scripts/mkisoimages.sh"
    fi

    log "Creating ISO using mkisoimages.sh (canonical single path — EFI and BIOS hybrid)..."
    ( cd "${CWD}/resources/scripts" && sh ./mkisoimages.sh -b "${LABEL}" "${ISO_PATH}" "${CD_ROOT}" )

    
    log "ISO created at: ${ISO_PATH}"
    # No .sha256 sidecar — GitHub shows each release asset's digest natively
    # (see the shared publish-continuous action and the naming convention).
}

split()
{
  # units -o "%0.f" -t "2 gigabytes" "bytes"
  THRESHOLD_BYTES=2147483647
  # THRESHOLD_BYTES=1999999999
  ISO_SIZE=$(stat -f%z "${ISO_PATH}")
  if [ $ISO_SIZE -gt $THRESHOLD_BYTES ] ; then
    echo "Size exceeds GitHub Releases file size limit; splitting the ISO"
    sudo split -d -b "$THRESHOLD_BYTES" -a 1 "${ISO_PATH}" "${ISO_PATH}.part"
    echo "Split the ISO, deleting the original"
    rm "${ISO_PATH}"
    ls -l "${ISO_PATH}"*
  fi
}

# --- Main Execution ---
log_env
setup_workspace
install_base_system
install_gershwin_software
build_gershwin_components
configure_system
downsize_system
prepare_boot_env
generate_iso
if [ -n "${CIRRUS_CI:-}" ] ; then
  # On Cirrus CI we want to upload to GitHub Releases which has a 2 GB file size limit,
  # hence we need to split the ISO there if it is too large
  split
fi

log "Build complete!"
