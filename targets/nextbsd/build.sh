#!/bin/sh
# build.sh — build a Gershwin live ISO on top of NextBSD, assembled FROM PACKAGES.
#
# Runs inside a FreeBSD 15.1 VM (vmactions). The NextBSD base+kernel+Darwin
# userland+kexts are laid down by ONE `pkg install NextBSD-everything` out of
# the nextbsd-pkg flat repo (the same source of truth nextbsd-redux/nextbsd's
# own build.sh now uses — #359), NOT by downloading a prebuilt continuous .img
# and ripping its rootfs out of GPT p3. The user-editable /etc config is seeded
# from the nextbsd-overlays repo (deliberately NOT package-owned). We then
# chroot-build the Gershwin desktop into that rootfs, lay the Gershwin launchd
# overlay (loginwindow/dshelper/gdomap + the D-Bus system bus) on top, and
# repackage the result into a live ISO that boots exactly like NextBSD's own —
# a tiny mfsroot assembles an on-demand uzip-compressed root + tmpfs/unionfs
# overlay, then `sysctl vfs.pivot` adopts the union as / and execs launchd.
#
# The rootfs-assembly half (steps 1-4) mirrors nextbsd-redux/nextbsd build.sh
# steps 1-6; the ISO-building half (steps 6-8) mirrors its step 7 — so both the
# package set and the boot pipeline stay identical to upstream NextBSD.
set -eu

ARCH=${TARGET_ARCH:-amd64}
FREEBSD_VERSION=${FREEBSD_VERSION:-15.1}
LABEL=GERSHWIN
CWD=$(cd "$(dirname "$0")" && pwd)
WORK=/usr/local/gon-build
ROOTFS=$WORK/rootfs
OUT=$WORK/iso
GERSHWIN_REPO=${GERSHWIN_REPO:-https://github.com/gershwin-desktop/gershwin-developer.git}
GERSHWIN_REF=${GERSHWIN_REF:-main}
# Optional source-repo branch passed to checkout.sh (e.g. GERSHWIN_BRANCH=dev for
# the dev channel). Empty = default branches, per-repo fallback. See checkout.sh.
GERSHWIN_BRANCH="${GERSHWIN_BRANCH:-}"
IMG_DATE=$(date -u +%Y%m%d%H%M%S)
# Canonical artifact name, shared by EVERY Gershwin flavor (see the naming
# convention in pkgdemon.github.io):
#   gershwin-on-<flavor>-<UTC YYYYMMDDhhmmss>-<arch>.iso
# `arch` is the release token (x86_64 / aarch64) — NOT the FreeBSD $ARCH
# (amd64), which stays as-is for the pkg ABI, repo URLs and mkisoimages.sh below.
FLAVOR=nextbsd
case "$ARCH" in
  amd64|x86_64)  ARCH_LABEL=x86_64 ;;
  arm64|aarch64) ARCH_LABEL=aarch64 ;;
  *)             ARCH_LABEL="$ARCH" ;;
esac
# Release channel (rc/dev) infixed after the flavor when set; empty = no channel.
CHANNEL="${CHANNEL:-}"
ISO_NAME="gershwin-on-${FLAVOR}-${CHANNEL:+${CHANNEL}-}${IMG_DATE}-${ARCH_LABEL}.iso"

# pkg uses `aarch64` for 64-bit ARM; release tags / artifact names use `arm64`.
case "$ARCH" in arm64|aarch64) ABIARCH=aarch64 ;; *) ABIARCH="$ARCH" ;; esac
PKG_ABI="FreeBSD:15:${ABIARCH}"
# nextbsd-pkg flat repo: per-arch rolling release tag (continuous-<arch>).
PKG_REPO_URL="https://github.com/nextbsd-redux/nextbsd-pkg/releases/download/continuous-${ARCH}"

rm -rf "$WORK"
mkdir -p "$WORK" "$ROOTFS" "$OUT"

# ---------------------------------------------------------------------------
# 1. Install the whole NextBSD OS from packages into the rootfs.
#    One `pkg install NextBSD-everything` lays down freebsd-compat base +
#    kernel + Darwin userland (incl. /sbin/launchd) + kexts. Host-driven
#    (`pkg -r $ROOTFS`, no chroot) — the NextBSD-* packages ship no exec'ing
#    post-install scripts, so this is arch-agnostic.
# ---------------------------------------------------------------------------
echo "==> pkg install NextBSD-everything into rootfs (ABI $PKG_ABI, stamp $IMG_DATE)"

# BOOTSTRAP pkg TLS: rehash the build VM's CA store so pkg can fetch the NextBSD
# flat repo over https (GitHub release assets). certctl ships in the base VM.
certctl rehash 2>/dev/null || true

# ISOLATE to ONLY the NextBSD repo. The vmactions VM ships enabled FreeBSD
# pkgbase/ports repos SIGNED with keys we don't have (they error "Error loading
# trusted certificates" and jam the SAT solver). Point pkg at a private
# REPOS_DIR that contains just the unsigned NextBSD flat repo.
NBREPO="$WORK/nbrepo"; mkdir -p "$NBREPO"
cat > "$NBREPO/NextBSD.conf" <<CONF
NextBSD: {
  url: "${PKG_REPO_URL}",
  enabled: yes,
  signature_type: none,
}
CONF

# ABI=FreeBSD:15:<arch>; OSVERSION is required when ABI is set (VM kernel value
# is right); IGNORE_OSVERSION so the rolling snapshot's stamp doesn't gate.
export ASSUME_ALWAYS_YES=yes IGNORE_OSVERSION=yes
export ABI="$PKG_ABI" OSVERSION="$(uname -K)"
PKG="pkg -r $ROOTFS -o REPOS_DIR=$NBREPO"
$PKG update -f
$PKG install -y NextBSD-everything
[ -x "$ROOTFS/sbin/launchd" ] || { echo "ERROR: NextBSD-everything install produced no /sbin/launchd" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2. Apple /private layout + runtime skeleton, then seed the pkg-free /etc.
#    The package ships /private/etc but NOT the /etc,/var,/tmp -> private
#    symlinks; create them, then lay the admin-owned /etc from nextbsd-overlays
#    (NOT package-owned, so `pkg upgrade` never clobbers accounts/SSH/PAM).
# ---------------------------------------------------------------------------
echo "==> Apple /private layout + nextbsd-overlays /etc seed"
mkdir -p "$ROOTFS/private"
for _pd in etc var tmp; do
    if [ -d "$ROOTFS/$_pd" ] && [ ! -L "$ROOTFS/$_pd" ]; then
        mv "$ROOTFS/$_pd" "$ROOTFS/private/$_pd"
    else
        mkdir -p "$ROOTFS/private/$_pd"
    fi
    ln -s "private/$_pd" "$ROOTFS/$_pd"
done

OVL="$WORK/nextbsd-overlays"
rm -rf "$OVL"
git clone --depth 1 https://github.com/nextbsd-redux/nextbsd-overlays "$OVL"
cp -R "$OVL/rootfs/." "$ROOTFS/"
chmod 0600 "$ROOTFS/private/etc/master.passwd"
[ -s "$ROOTFS/private/etc/master.passwd" ] || { echo "ERROR: nextbsd-overlays seed produced no master.passwd" >&2; exit 1; }

# launchd -w job-overrides DB dir + /var runtime skeleton (PAM pam_open_session
# needs utx.* or login aborts; locale(1) err()s without /usr/share/locale).
mkdir -p "$ROOTFS/private/var/db/launchd.db/com.apple.launchd"
mkdir -p "$ROOTFS/var/run" "$ROOTFS/var/log" "$ROOTFS/var/db" "$ROOTFS/var/empty" \
         "$ROOTFS/var/tmp" "$ROOTFS/tmp" "$ROOTFS/dev" "$ROOTFS/usr/share/locale"
chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"
: > "$ROOTFS/var/run/utx.active"; : > "$ROOTFS/var/log/utx.lastlogin"; : > "$ROOTFS/var/log/utx.log"
chmod 644 "$ROOTFS/var/run/utx.active" "$ROOTFS/var/log/utx.lastlogin" "$ROOTFS/var/log/utx.log"
mkdir -p "$ROOTFS/root"; chmod 0700 "$ROOTFS/root"

# ---------------------------------------------------------------------------
# 3. Regenerate /etc databases + configure pkg repos in the SHIPPED image so
#    the Gershwin chroot build (and a user later) can `pkg install` out of the
#    box. Two repos: FreeBSD ports (Gershwin's deps) + the NextBSD flat repo.
# ---------------------------------------------------------------------------
echo "==> regenerate /etc databases + configure image pkg repos"
chown -RH 0:0 "$ROOTFS/etc" 2>/dev/null || true
pwd_mkdb -p -d "$ROOTFS/etc" "$ROOTFS/etc/master.passwd"
[ -f "$ROOTFS/etc/login.conf" ] && cap_mkdb "$ROOTFS/etc/login.conf"
[ -f "$ROOTFS/usr/share/misc/termcap" ] && cap_mkdb "$ROOTFS/usr/share/misc/termcap" || true
env DESTDIR="$ROOTFS" certctl rehash 2>/dev/null || true

mkdir -p "$ROOTFS/usr/local/etc/pkg/repos"
cat > "$ROOTFS/usr/local/etc/pkg/repos/FreeBSD.conf" <<CONF
FreeBSD: {
  url: "pkg+https://pkg.FreeBSD.org/FreeBSD:15:${ABIARCH}/latest",
  mirror_type: "srv",
  enabled: yes
}
CONF
cat > "$ROOTFS/usr/local/etc/pkg/repos/NextBSD.conf" <<CONF
NextBSD: {
  url: "${PKG_REPO_URL}",
  enabled: yes,
  signature_type: none,
}
CONF
cat > "$ROOTFS/usr/local/etc/pkg.conf" <<CONF
ABI = "FreeBSD:15:${ABIARCH}";
IGNORE_OSVERSION = yes;
CONF

# ---------------------------------------------------------------------------
# 4. Version identity — the SAME /etc/os-release nextbsd-redux/nextbsd build.sh
#    writes (it is NOT shipped by the package or nextbsd-overlays). Two reasons
#    it MUST exist before the chroot build below:
#      - Gershwin's Bootstrap.sh keys its dependency set off `. /etc/os-release`
#        -> $ID. Without it, Bootstrap falls back to `uname -s`, which inside the
#        chroot is the vmactions VM's FreeBSD kernel, NOT NextBSD -> it would pick
#        Library/OSSupport/freebsd.txt and `pkg install mDNSResponder`, which
#        collides with NextBSD's own base mDNSResponder. ID=nextbsd selects
#        nextbsd.txt (which correctly omits it).
#      - It brands the shipped image and gives nextbsd-version a value.
# ---------------------------------------------------------------------------
echo "==> version identity: /etc/os-release (ID=nextbsd) + nextbsd-version"
cat > "$ROOTFS/etc/os-release" <<OSREL
NAME="NextBSD"
PRETTY_NAME="Gershwin on NextBSD ${IMG_DATE}"
ID=nextbsd
ID_LIKE=freebsd
VERSION="${IMG_DATE}"
VERSION_ID="15.1"
HOME_URL="https://nextbsd.org"
OSREL
if [ ! -x "$ROOTFS/bin/nextbsd-version" ]; then
    cat > "$ROOTFS/bin/nextbsd-version" <<NBV
#!/bin/sh
echo "NextBSD ${IMG_DATE}"
NBV
    chmod 0555 "$ROOTFS/bin/nextbsd-version"
fi

# ---------------------------------------------------------------------------
# 5. Build Gershwin into the rootfs via chroot (network for pkg + git clone).
#    Same flow as the other Gershwin targets; detect_platform() takes the
#    NextBSD path because /usr/lib/system exists in the rootfs. Gershwin's
#    Bootstrap.sh installs the X11/dbus/cairo/... build+runtime deps from the
#    FreeBSD repo configured in step 3.
# ---------------------------------------------------------------------------
echo "==> chroot build: Gershwin -> /System"
mount -t devfs devfs "$ROOTFS/dev"
cp /etc/resolv.conf "$ROOTFS/private/etc/resolv.conf"
chroot "$ROOTFS" /bin/sh -eu -c '
    pkg install -y git
    git clone --depth 1 -b '"$GERSHWIN_REF"' '"$GERSHWIN_REPO"' /Developer
    cd /Developer
    sh Library/Scripts/bootstrap.sh
    BRANCH='"$GERSHWIN_BRANCH"' sh Library/Scripts/checkout.sh
    make install
'
[ -d "$ROOTFS/System/Library" ] || { echo "ERROR: /System was not produced" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 6. Bake the runtime prerequisites Gershwin needs but never installs itself —
#    the XLibre X server + input/video drivers (pkglist.txt). Gershwin's
#    LoginWindow execs /usr/local/bin/X at boot; its Bootstrap.sh installs only
#    the X *client* libs, and the NextBSD base no longer bundles a server (it
#    rebuilt from packages), so the desktop can't start without this. Installed
#    IN THE CHROOT (devfs + resolv.conf still present from step 5) so each
#    package's post-install scripts run natively; pkg resolves the full closure
#    from the FreeBSD repo configured in step 3.
# ---------------------------------------------------------------------------
if [ -f "$CWD/pkglist.txt" ]; then
    EXTRA_PKGS=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$CWD/pkglist.txt" | tr '\n' ' ')
    if [ -n "$EXTRA_PKGS" ]; then
        echo "==> installing pkglist.txt runtime prerequisites: $EXTRA_PKGS"
        chroot "$ROOTFS" /bin/sh -eu -c "pkg install -y $EXTRA_PKGS"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Gershwin launchd overlay: loginwindow/dshelper/gdomap + the D-Bus system
#    bus (keep base getty as a rescue console on the other VTs).
# ---------------------------------------------------------------------------
echo "==> applying Gershwin launchd overlay (loginwindow alongside getty)"
cp -aR "$CWD/overlays/." "$ROOTFS/"
# Keep NextBSD's base getty job (com.apple.getty.plist). launchd is PID 1 and
# does not read /etc/ttys, so loginwindow is the only login path once getty is
# removed -- if the greeter/X dies there is no console login on any VT and the
# machine is reachable only via SSH. Retaining getty leaves a text rescue
# console on the other VTs. loginwindow stays the primary GUI greeter.

# D-Bus system bus: the org.freedesktop.dbus-system LaunchDaemon (overlay) runs
# `dbus-daemon --system` in the foreground. It needs a machine-id (generate now
# so every live boot has one) and the /var/run/dbus socket dir to exist; the
# live overlay makes /var writable so the socket itself is created at runtime.
echo "==> D-Bus: machine-id + /var/run/dbus socket dir"
chroot "$ROOTFS" /bin/sh -eu -c '
    /usr/local/bin/dbus-uuidgen --ensure
    mkdir -p /var/run/dbus
'
[ -x "$ROOTFS/usr/local/bin/dbus-daemon" ] || { echo "ERROR: dbus-daemon absent -- Gershwin Bootstrap should have installed the dbus package" >&2; exit 1; }

# Initialize Gershwin DirectoryServices so loginwindow can authenticate: dscli
# init creates /Local (the local DS node) and /Volumes. dscli ships in
# /System/Library/Tools, only on PATH once GNUstep.sh is sourced -- source it
# first, then init inside the chroot. Must succeed: without it the greeter has
# no directory to auth against.
chroot "$ROOTFS" /bin/sh -c '. /System/Library/Makefiles/GNUstep.sh && dscli init'

# NB: create NO user account and never touch /etc/master.passwd. `dscli init`
# above already provisioned the live 'admin' in DirectoryServices (uid/gid 5000,
# noPassword, home /Local/Users/admin) and the greeter authenticates it via
# dshelper/nss_gershwin. A pw(8) /etc account would be a redundant, conflicting
# second 'admin' -- Gershwin owns the user database, so we leave it entirely to
# dscli (which also sets the correct /Local ownership; we must not disturb it).

# purge the pkg cache before makefs bakes the tree in. All three install phases
# (NextBSD-everything, Gershwin's Bootstrap.sh deps, pkglist.txt) leave the
# downloaded package tarballs + metadata under /var/cache/pkg in the rootfs;
# nothing needs them at runtime, and they otherwise go straight into the
# compressed image. Run in the chroot (devfs still mounted from step 5) so pkg
# operates on the rootfs's own db/cache.
echo "==> pkg clean: purge cached package tarballs from the rootfs"
chroot "$ROOTFS" /bin/sh -eu -c 'pkg clean -ay' || true

# ...and the remote repository catalogues, which `pkg clean` does NOT remove: it
# only empties PKG_CACHEDIR (/var/cache/pkg), while the catalogues sit under
# PKG_DBDIR (/var/db/pkg/repos/<repo>/db). Same build residue, same reasoning as
# the tarballs -- nothing needs them at runtime and pkg refetches them on the
# installed system (REPO_AUTOUPDATE defaults to YES). On gershwin-on-freebsd
# these had grown to 1.66 GiB *each* once the upstream `latest` catalogue
# ballooned, adding ~446 MiB to the compressed image. Path goes through
# private/ because of the Apple /private layout established in step 3; the
# installed-package registry (local.sqlite) lives in PKG_DBDIR too and stays.
rm -rf "$ROOTFS/private/var/db/pkg/repos"

# Deliberately KEEP /Developer (the gershwin-developer clone + its checked-out
# Library/Sources) baked into the rootfs, exactly as gershwin-on-freebsd does:
# it rides along in rootfs.uzip -> the rofs lower layer, so the live desktop
# ships with a full on-disk Developer source tree once cow+rofs are unioned as
# /. It never enters the mfsroot/miniroot (that only copies the fixed tool list
# above), so single-user boot stays tiny. Only the transient resolv.conf goes.
rm -rf "$ROOTFS/private/etc/resolv.conf"
umount "$ROOTFS/dev" || true

# Retire the kld* user CLIs, exactly as nextbsd-redux/nextbsd build.sh does so
# the Gershwin ISO carries the same Apple-shape base: macOS ships kextload/
# kextstat, not kldload. Only the CLI front-ends go; the kld*(2) syscalls stay
# and kext_tools provides the replacements. Harmless if a name is absent.
rm -f "$ROOTFS/sbin/kldload" "$ROOTFS/sbin/kldunload" "$ROOTFS/sbin/kldstat" \
      "$ROOTFS/sbin/kldconfig" "$ROOTFS/usr/sbin/kldxref" \
      "$ROOTFS/usr/lib/debug/usr/sbin/kldxref.debug"

# Normalise ownership of ONLY the launchd overlay we cp'd in from the repo: those
# plists can carry the build user's uid from the rsync'd workspace. Do NOT
# blanket-chown the whole rootfs -- that clobbers the DirectoryServices ownership
# `dscli init` set up (notably /Local/Users/admin -> 5000:5000), which the
# logged-in session needs to write its home; a root-owned home makes the session
# fail to start and X drops back to the greeter. Everything else is already
# root-owned (pkg -r, chroot, and the overlay clones/cp all run as root here).
echo "==> normalising launchd overlay ownership to root:wheel"
chown -R 0:0 "$ROOTFS/System/Library/LaunchDaemons"

# ---------------------------------------------------------------------------
# 8-10. Repackage as a live ISO (nextbsd build.sh step 7 model, verbatim).
# ---------------------------------------------------------------------------
echo "==> live ISO: compact UFS + mkuzip (zstd)"
# --- ISO SIZE REPORT (exact, uncompressed): every installed package by flatsize
#     + the biggest directories that ship in the rootfs. Ground truth for what
#     inflates the image (pkg logs only show aggregate sizes). Non-fatal.
echo "=================== ISO SIZE REPORT (nextbsd) ==================="
echo "--- installed packages by flatsize (MiB, top 40) ---"
chroot "$ROOTFS" pkg query '%sb %n-%v' 2>/dev/null \
  | sort -rn | awk '{printf "  %9.1f  %s\n", $1/1048576, $2}' | head -40 || true
echo "--- total installed (all packages, MiB) ---"
chroot "$ROOTFS" pkg query '%sb' 2>/dev/null \
  | awk '{s+=$1} END{printf "  %9.1f  (n=%d packages)\n", s/1048576, NR}' || true
echo "--- biggest directories in the rootfs (MiB, top 30) ---"
du -sm "$ROOTFS"/usr/local/* "$ROOTFS"/Developer \
       "$ROOTFS"/System "$ROOTFS"/usr/lib "$ROOTFS"/boot 2>/dev/null \
  | sort -rn | head -30 || true
echo "--- inside /usr/local/share (MiB, top 20) ---"
du -sm "$ROOTFS"/usr/local/share/* 2>/dev/null | sort -rn | head -20 || true
echo "--- inside /usr/local/lib (MiB, top 20) ---"
du -sm "$ROOTFS"/usr/local/lib/* 2>/dev/null | sort -rn | head -20 || true
echo "--- rootfs total (MiB) ---"; du -sm "$ROOTFS" 2>/dev/null || true
echo "================================================================"
makefs -t ffs -B little -o version=2,label=NBROOT "$WORK/rootfs.iso.ufs" "$ROOTFS"
# Compress the rootfs with zstd (-A), NOT mkuzip's default zlib: zstd roughly
# doubles the ratio vs zlib on this tree while keeping the fastest on-demand
# geom_uzip decompression at runtime. -d de-duplicates identical clusters.
#
# mkuzip compresses every cluster as an INDEPENDENT zstd frame, so the cluster size
# IS the compressor's window: at mkuzip's 16K default it restarts with an empty
# window every 16 KiB across an 8 GB image and can never reference the identical ELF
# headers/string tables a few clusters away. Two knobs, and they cost very different
# amounts: the LEVEL costs CPU, the CLUSTER is nearly free (wider clusters mean fewer
# of them, so less per-cluster overhead -- it compresses FASTER).
#
# Measured against the real rootfs.iso.ufs, not modeled (the shipped image was pulled
# from the published ISO, decompressed back to raw UFS, and each setting re-run on the
# actual bytes; the then-current setting reproduced the shipped uzip to -0.0%):
#
#     -C 19  -s 128K   2.031 GB    --      188s   <- what we shipped before this change
#     -C 15  -s 128K   2.055 GB   +1.2%     69s   <- LARGER; low level wastes the window
#     -C 15  -s   1M   2.000 GB   -1.5%     48s   <- fastest, if build time is the goal
#     -C 19  -s   1M   1.859 GB   -8.4%    155s   <- smaller AND faster than 128K
#     -A lzma -s  1M   1.745 GB  -14.0%    164s   <- rejected, see below
#
# So a ~1 MiB cluster is strictly better than the 128K it replaces: ~170 MB smaller and
# ~3 min faster in CI.
#
# Why 1044480 and not 1048576: there are TWO ceilings and the tighter one is in mkuzip,
# not the kernel. The kernel caps the *uncompressed* cluster at maxphys (MAX_BLKSZ in
# sys/geom/uzip/g_uzip.c), which would allow a full 1 MiB. But mkuzip additionally
# requires the WORST-CASE COMPRESSED cluster to fit in MAXPHYS -- an incompressible
# cluster grows -- and rejects -s 1048576 outright:
#
#     mkuzip: maximal compressed cluster size 1052672 greater than MAXPHYS 1048576
#
# The overhead it budgets is one 4 KiB page, so the true maximum is 1048576 - 4096 =
# 1044480 (a valid multiple of 512). That is within 0.4% of 1 MiB, so it keeps
# essentially all of the win. Do not "round this up" to 1048576; the build will fail.
#
# Read cost: geom_uzip decompresses a whole cluster to satisfy ANY read, so a wider
# cluster taxes small reads on the live root. Measured over 300 real clusters:
#
#     zstd -C 19  128K   1545 MB/s   median 0.08 ms/cluster   p95 0.15 ms
#     zstd -C 19    1M   1660 MB/s   median 0.62 ms/cluster   p95 1.10 ms
#     lzma          1M    132 MB/s   median 5.99 ms/cluster   p95 17.68 ms
#
# 0.62 ms is an acceptable tax, and zstd's ~1.6 GB/s is ~10x faster than any live
# medium (USB2 ~30 MB/s, USB3 ~100-300 MB/s), so decompression never bottlenecks boot.
#
# lzma IS supported here (geom_uzip decodes it unconditionally; zstd is the one gated
# behind ZSTDIO) and is ~6% smaller at matched settings -- but it decompresses ~12x
# slower, at 132 MB/s, which is the same order as the live medium itself, so it would
# become the boot bottleneck. Note zstd at 1M (0.62 ms) still beats lzma at 128K
# (0.76 ms): zstd with a wide cluster dominates lzma outright. This is the same trade
# Ubuntu made when it moved its live squashfs from xz to zstd. Do not "optimise" this
# back to lzma without re-measuring decompression.
#
# -d de-duplicates identical clusters; -S prints the achieved ratio.
mkuzip -A zstd -C 19 -s 1044480 -d -S -o "$WORK/rootfs.uzip" "$WORK/rootfs.iso.ufs"
ls -lh "$WORK/rootfs.uzip"

echo "==> staging mfsroot (rootfs tools + lib closure)"
MFS="$WORK/mfsroot"
RF="$ROOTFS"
rm -rf "$MFS"
mkdir -p "$MFS/dev" "$MFS/media" "$MFS/rofs" "$MFS/cow" \
         "$MFS/bin" "$MFS/sbin" "$MFS/lib" "$MFS/libexec"
cp -p "$RF/libexec/ld-elf.so.1" "$MFS/libexec/"
MFS_TOOLS="bin/sh bin/sleep bin/ls sbin/mount sbin/umount sbin/mount_cd9660 sbin/mount_unionfs sbin/mdconfig sbin/sysctl"
for t in $MFS_TOOLS; do
    if [ -f "$RF/$t" ]; then cp -p "$RF/$t" "$MFS/$t"
    else echo "    WARN: mfsroot tool missing in rootfs: $t"; fi
done
needed() { readelf -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'; }
seen=" "
work=$(for t in $MFS_TOOLS; do [ -f "$MFS/$t" ] && needed "$MFS/$t"; done | sort -u)
while [ -n "$work" ]; do
    nextwork=""
    for so in $work; do
        case "$seen" in *" $so "*) continue ;; esac
        seen="$seen$so "
        src=$(find "$RF/lib" "$RF/usr/lib" /lib /usr/lib -name "$so" 2>/dev/null | head -1)
        if [ -n "$src" ]; then
            cp -p "$src" "$MFS/lib/$so"
            nextwork="$nextwork $(needed "$src")"
        else
            echo "    WARN: mfsroot lib not found: $so"
        fi
    done
    work=$(printf '%s\n' $nextwork | sort -u)
done

cat > "$MFS/init" <<'INITEOF'
#!/bin/sh
# Gershwin/NextBSD live-ISO init. Runs as PID 1 from the preloaded mfsroot,
# assembles an on-demand uzip root + tmpfs/unionfs overlay, then vfs.pivot
# adopts the union as / and execs launchd.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/libexec
LD_LIBRARY_PATH=/lib
export PATH LD_LIBRARY_PATH

mount -t devfs devfs /dev 2>/dev/null
exec >/dev/console 2>&1
echo "[init] Gershwin/NextBSD live root: assembling overlay"

n=0
while [ ! -e /dev/iso9660/GERSHWIN ] && [ ! -e /dev/cd0 ] && [ "$n" -lt 10 ]; do n=$((n + 1)); sleep 1; done
for dev in /dev/iso9660/GERSHWIN /dev/cd0 /dev/cd1; do
	[ -e "$dev" ] || continue
	if mount -t cd9660 -o ro "$dev" /media 2>&1; then
		echo "[init] media mounted from $dev"; break
	fi
done
echo "[init] media: $(ls /media/rootfs.uzip 2>/dev/null || echo rootfs.uzip-MISSING)"

mdconfig -a -t vnode -f /media/rootfs.uzip -u 1
n=0
while [ ! -c /dev/md1.uzip ] && [ "$n" -lt 20 ]; do n=$((n + 1)); sleep 1; done
mount -o ro /dev/md1.uzip /rofs
echo "[init] rofs lower: $(ls -d /rofs/sbin 2>/dev/null || echo /rofs-EMPTY)"

case " $* " in
*" -s "*)
	echo "[init] ==== single-user (miniroot) ===="
	/bin/sh </dev/console >/dev/console 2>&1
	echo "[init] resuming boot to multi-user"
	;;
esac

mount -t tmpfs tmpfs /cow
mount_unionfs /cow /rofs
echo "[init] union assembled; launchd: $(ls /rofs/sbin/launchd 2>/dev/null || echo launchd-MISSING)"
mount -t devfs devfs /rofs/dev

sysctl vfs.pivot=/rofs
echo "[init] pivot complete; exec launchd"
unset LD_LIBRARY_PATH
exec /sbin/launchd
echo "[init] FATAL: exec /sbin/launchd failed ($?)"
while : ; do sleep 60; done
INITEOF
chmod 0755 "$MFS/init"
chown -R 0:0 "$MFS"
makefs -t ffs -B little -o version=2,label=MFSROOT -b 3m "$WORK/mfsroot.img" "$MFS"

echo "==> assembling ISO staging tree"
ISOROOT="$WORK/isoroot"
rm -rf "$ISOROOT"
mkdir -p "$ISOROOT/boot/loader.conf.d" "$ISOROOT/etc"
cp -R "$ROOTFS/boot/." "$ISOROOT/boot/"
# cdboot is the BIOS El Torito boot block — amd64 only; arm64 ISOs are UEFI-only
# (booted from loader.efi via the ESP El Torito image). Require cdboot only when
# it exists; loader.efi is required on both (matches nextbsd build.sh).
_isoreq="loader.efi"
[ -f "$ISOROOT/boot/cdboot" ] && _isoreq="cdboot loader.efi"
for f in $_isoreq; do
    [ -f "$ISOROOT/boot/$f" ] || { echo "ERROR: live ISO needs rootfs/boot/$f" >&2; exit 1; }
done
cp "$WORK/mfsroot.img" "$ISOROOT/boot/mfsroot.img"
for f in passwd group master.passwd; do
    [ -f "$ROOTFS/etc/$f" ] && cp "$ROOTFS/etc/$f" "$ISOROOT/etc/$f"
done
cat > "$ISOROOT/boot/loader.conf.d/zz-live.conf" <<'LIVEEOF'
# Gershwin/NextBSD live ISO: tiny mfsroot assembles an on-demand compressed root + overlay.
mfsroot_load="YES"
mfsroot_type="md_image"
mfsroot_name="/boot/mfsroot.img"
init_path="/init"
vfs.root.mountfrom="ufs:/dev/md0"
LIVEEOF
cp "$WORK/rootfs.uzip" "$ISOROOT/rootfs.uzip"

# Use FreeBSD's stock release scripts from src.txz (matching the base version),
# exactly as nextbsd-redux/nextbsd does — the full tree resolves mkisoimages.sh's
# relative sources (scripts/tools.subr, tools/boot/install-boot.sh).
echo "==> fetching FreeBSD ${FREEBSD_VERSION} src.txz for release scripts"
SRC="$WORK/freebsd-src"
mkdir -p "$SRC"
fetch -o "$WORK/src.txz" "https://download.freebsd.org/ftp/releases/${ARCH}/${FREEBSD_VERSION}-RELEASE/src.txz"
tar -xJf "$WORK/src.txz" -C "$SRC"
MKISO=$(find "$SRC" -path "*/release/${ARCH}/mkisoimages.sh" 2>/dev/null | head -1)
[ -n "$MKISO" ] || { echo "ERROR: mkisoimages.sh not found in src.txz" >&2; exit 1; }

echo "==> mkisoimages.sh: bootable cd9660 (BIOS + UEFI)"
sh "$MKISO" -b "$LABEL" "$OUT/$ISO_NAME" "$ISOROOT"
ls -lh "$OUT/$ISO_NAME"
echo "==> DONE: $ISO_NAME"
