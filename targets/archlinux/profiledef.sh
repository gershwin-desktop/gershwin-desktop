#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="gershwin-on-arch"
iso_label="Gershwin_on_Arch_$(date +%Y%m)"
iso_publisher="Gershwin"
iso_application="Gershwin on Arch Linux"
iso_version="$(date +%Y.%m.%d)"
# archiso >= 89 validates install_dir against ^[a-z0-9]+$ — no hyphens.
install_dir="gershwinarch"
buildmodes=('iso')
quiet="y"
# UEFI boots via GRUB, not systemd-boot, to keep the ISO under GitHub's 2 GiB
# release-asset limit. systemd-boot can only read the EFI system partition it was
# launched from, so mkarchiso copies the kernel + initramfs + microcode into
# efiboot.img on top of the copy it already writes to ISO 9660 for syslinux. With
# a ~207 MiB initramfs (the kms hook bundles ~145 MiB of GPU firmware, stored
# uncompressed because it is already zstd) that duplicate cost ~237 MiB and
# pushed the ISO to 2048.0 MiB -- 208 KiB over the limit. GRUB reads iso9660, so
# efiboot.img carries only GRUB and the UEFI shell. See targets/archlinux/grub/.
bootmodes=('bios.syslinux' 'uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
# Already the maximum squashfs can do -- do not go looking for a better setting
# here when the ISO grows. 1M is mksquashfs's hard ceiling on block size
# ("-b block size not power of two or not between 4096 and 1Mbyte") and the xz
# dictionary cannot exceed it ("-Xdict-size is larger than block_size"), so both
# knobs are pinned at their limit. Re-packing the 2026-07-26 airootfs (3597 MiB
# of file data) every other way measured worse: this = 1463.8 MiB, xz without
# -Xbcj x86 = 1474.1 MiB, zstd -Xcompression-level 22 = 1523.8 MiB.
# Size wins come from the boot payload and image contents instead.
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
)
