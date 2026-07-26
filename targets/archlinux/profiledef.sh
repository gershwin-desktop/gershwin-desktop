#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="gershwin-on-arch"
iso_label="Gershwin_on_Arch_$(date +%Y%m)"
iso_publisher="Gershwin"
iso_application="Gershwin on Arch Linux"
iso_version="$(date +%Y.%m.%d)"
install_dir="gershwin-arch"
buildmodes=('iso')
quiet="y"
bootmodes=('bios.syslinux' 'uefi.systemd-boot')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
)
