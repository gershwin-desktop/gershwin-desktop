# gershwin-desktop

Gershwin is a desktop environment based on GNUstep welcoming to switchers.

<img width="1920" height="1080" alt="gershwin-20260129" src="https://github.com/user-attachments/assets/c20330bd-55a2-4a41-a4ec-df6d488a5246" />

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

* Gershwin can be installed in under a few minutes by using [gershwin-build](https://github.com/gershwin-desktop/gershwin-build).

* GhostBSD users can also install Gershwin by installing following package (currently not up to date):
```
 # pkg install gershwin-desktop
```

* Testers can try a [gershwin-on-debian live iso](https://github.com/gershwin-desktop/gershwin-on-debian/releases/tag/continuous) (most up to date), or [gershwin-on-arch live iso](https://github.com/gershwin-desktop/gershwin-on-arch/releases/tag/continuous), or the [GhostBSD Gershwin Community Preview live iso](https://www.ghostbsd.org/download).

## Community Support

All community support tickets and feature requests should be created through our [community issue tracker](https://github.com/gershwin-desktop/issues).

For questions and other feedback, the [Github Discussions](https://github.com/orgs/gershwin-desktop/discussions) is a great place to reach out.

There is also `#gershwin` on Libera Chat, but be aware that answers may take several days since this is all run by volunteers.

## Contributing

Please see our help wanted section under our [GitHub project](https://github.com/orgs/gershwin-desktop/projects/1).

For resources to get started with development:

* http://developer.gnustep.org/
