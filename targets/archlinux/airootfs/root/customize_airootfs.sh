#!/bin/bash

set -ex

# Prepare Arch Linux Pacman directory
# in an effort to fix "not enough free disk space" error
sed -i -e 's|^CheckSpace|# CheckSpace|g' /etc/pacman.conf # Comment out CheckSpace
pacman -Scc --noconfirm
pacman-key --init
pacman-key --populate archlinux

# Trust the XLibre signing key in the ISO's own keyring as well, so the running
# system can install and update XLibre packages -- the [xlibre] repo is in the
# shipped pacman.conf. Same full-fingerprint pin as the build-time import in the
# workflow: a swapped key fails here rather than being trusted.
xlibre_fpr=0C92313001CFCA27627B9098B97F7C613F359424
curl -fsSL -o /tmp/xlibre.asc https://xlibre-arch.github.io/xlibre-archlinux.asc
# Own GNUPGHOME for the fingerprint check: this runs in the airootfs chroot with
# HOME inherited from the build environment (/github/home on CI), which does not
# exist in here, and gpg fatals trying to create its homedir under it.
xlibre_gnupg="$(mktemp -d)"
GNUPGHOME="$xlibre_gnupg" gpg --show-keys --with-colons /tmp/xlibre.asc \
  | awk -F: '/^fpr:/{print $10}' | grep -qx "$xlibre_fpr"
rm -rf "$xlibre_gnupg"
pacman-key --add /tmp/xlibre.asc
pacman-key --lsign-key "$xlibre_fpr"
rm -f /tmp/xlibre.asc

# Some GNUstep build scripts need /proc
mount -t proc proc /proc

# https://github.com/gershwin-desktop/gershwin-developer
git clone -b "${GERSHWIN_REF:-main}" https://github.com/gershwin-desktop/gershwin-developer.git /Developer
/Developer/Library/Scripts/bootstrap.sh
BRANCH="${GERSHWIN_BRANCH:-}" /Developer/Library/Scripts/checkout.sh
cd /Developer && sudo -E make install

. /System/Library/Makefiles/GNUstep.sh

# Everything that comes with the System should be in /System
mkdir -p /System/Applications /System/Library/Tools
sudo mv /Local/Applications/* /System/Applications || true
sudo mv /Local/Library/Tools/* /System/Library/Tools || true

# Initialize Directory Services (creates built-in admin user with no password)
dscli init

# Enable services for the live session
systemctl enable gdomap dshelper loginwindow avahi-daemon

# Allow empty password for sshd
sed -i 's/^[[:space:]#]*PermitEmptyPasswords[[:space:]]*.*/PermitEmptyPasswords yes/' /etc/ssh/sshd_config

# Configure LoginWindow for auto-login
mkdir -p /Local/Library/Preferences
cat > /Local/Library/Preferences/LoginWindow.plist <<\EOF
{
    lastLoggedInUser = admin;
    lastSession = "/System/Library/Scripts/Gershwin.sh";
}
EOF

# Otherwise ISO creation fails
umount /proc

# Set boot splash theme
# Now handled by install-plymouth.sh in gershwin-system (invoked from
# SystemPrepare.sh), which sets the spinner theme on supported distributions.
# plymouth-set-default-theme spinner -R
