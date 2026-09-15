# Gershwin Desktop

Gershwin is a desktop environment based on GNUstep welcoming to switchers.

![2026-03-24 23 38 47](https://github.com/user-attachments/assets/d61c8a50-ae9b-4320-9937-0fb22455176e)

## Why Gershwin?

Gershwin offers Workspace, Terminal, TextEdit, System Preferences, a native Window Manager for X11 apps, Global Menu server for GNUstep/X11 apps, and more. 

* Gershwin can be built from source code in less than a few minutes using a First-class Clang/LLVM toolchain.
* The entire system including Window Manager only consumes under 50MB of storage.
* Gershwin is completely self contained from the underlying operating system.
* Local Users and Local Applications are kept separate from Network Users and Network Applications and System Applications.
* Users can install Application bundles without root credentials in the Users folder.
* Applications built using Gershwin and its underlying GNUstep foundation can run on other many operating systems including Windows.
* Multiple versions of core libraries can co-exist to guarantee long term ABI stability.

## Installation and testing

* Gershwin can be installed in under a few minutes by using [gershwin-developer](https://github.com/gershwin-desktop/gershwin-developer) (formerly `gershwin-build`), which builds and installs Gershwin from source on FreeBSD, GhostBSD, OpenBSD, Arch, Artix, Debian, Devuan and Void.

* Testers can try a live ISO. Every flavor is now published from **this** repository — the separate `gershwin-on-*` repos are gone. Download the newest build from the [tags page](https://github.com/gershwin-desktop/gershwin-desktop/tags), or pick one directly:

  | Flavor | Release candidate (`rc`) | Development (`dev`) |
  | --- | --- | --- |
  | FreeBSD | [freebsd-rc](https://github.com/gershwin-desktop/gershwin-desktop/releases/tag/freebsd-rc) | [freebsd-dev](https://github.com/gershwin-desktop/gershwin-desktop/releases/tag/freebsd-dev) |
  | NextBSD | [nextbsd-rc](https://github.com/gershwin-desktop/gershwin-desktop/releases/tag/nextbsd-rc) | [nextbsd-dev](https://github.com/gershwin-desktop/gershwin-desktop/releases/tag/nextbsd-dev) |
  | Debian | [debian-rc](https://github.com/gershwin-desktop/gershwin-desktop/releases/tag/debian-rc) | [debian-dev](https://github.com/gershwin-desktop/gershwin-desktop/releases/tag/debian-dev) |
  | Devuan | [devuan-rc](https://github.com/gershwin-desktop/gershwin-desktop/releases/tag/devuan-rc) | [devuan-dev](https://github.com/gershwin-desktop/gershwin-desktop/releases/tag/devuan-dev) |
  | Arch Linux | [archlinux-rc](https://github.com/gershwin-desktop/gershwin-desktop/releases/tag/archlinux-rc) | [archlinux-dev](https://github.com/gershwin-desktop/gershwin-desktop/releases/tag/archlinux-dev) |

  **rc** is built from the default branches of the Gershwin sources, **dev** from their `dev` branches. Each release is rolled forward continuously and carries a screenshot of the ISO booted to the desktop, taken by the same boot gate every flavor has to pass.

* GhostBSD users can also install Gershwin by installing following package (currently not up to date):
```
 # pkg install gershwin-desktop
```

Please see the [wiki](https://github.com/gershwin-desktop/gershwin-desktop/wiki) for more information.

## Building the live ISOs

This repository builds the Gershwin live ISOs for several base OSes (FreeBSD,
NextBSD, Debian, Devuan, Arch Linux) from one tree — each on an **rc** and a
**dev** release channel. Every flavor builds inside a container of its own
distribution using that distro's native live-media tooling, then shares one
boot/login/screenshot gate and one publish step.

To **add a new flavor** (e.g. Artix) or change how the ISOs are built, see
**[docs/ADDING-A-FLAVOR.md](docs/ADDING-A-FLAVOR.md)**. (Claude Code users: the
repo also ships an `add-iso-flavor` skill that automates the same procedure.)

## Wiki

The [Gershwin Desktop wiki](https://github.com/gershwin-desktop/gershwin-desktop/wiki) contains more information, including changelogs.

## Community Support

All community support tickets and feature requests should be created through our [community issue tracker](https://github.com/gershwin-desktop/issues).

For questions and other feedback, the [Github Discussions](https://github.com/orgs/gershwin-desktop/discussions) is a great place to reach out.

There is also `#gershwin` on Libera Chat, but be aware that answers may take several days since this is all run by volunteers.

## Contributing

Please see our help wanted section under our [GitHub project](https://github.com/orgs/gershwin-desktop/projects/1).

For resources to get started with development:

* http://developer.gnustep.org/
