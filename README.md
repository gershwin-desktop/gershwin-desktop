# gershwin-desktop
Gershwin is a desktop environment based on GNUstep with an early Mac OS X-like user experience. 

<img width="1918" height="1079" alt="Screenshot 2025-12-25 at 11 32 34 PM" src="https://github.com/user-attachments/assets/c28184d2-27e9-4499-aadd-3e6dc7d6e3dc" />

## Why Gershwin?

Gershwin offers Workspace, Terminal, TextEdit, System Preferences, a native Window Manager for X11 apps, Global Menu server for GNUstep/X11 apps, and more. 

* Gershwin can be built from source code in less than a few minutes on even low spec virtual machines with 1 GB memory 1 CPU
* The entire system including Window Manager only consumes under 50MB of storage
* Gershwin is completely self contained from the underlying operating system
* Local Users and Local Applications are kept seperate from Network Users and Network Applications and System Applications
* Users can install Application bundles without root credentials in the Users folder
* Applications built using Gershwin and it's underlying GNUstep foundation can run on other many operating systems including Windows

## Installation and testing

* Gershwin can be installed in under a few minutes by using [gershwin-build](https://github.com/gershwin-desktop/gershwin-build).

* Testers can try a [gershwin-on-debian live iso](https://github.com/gershwin-desktop/gershwin-on-debian/releases/tag/continuous) or [gershwin-on-arch live iso](https://github.com/gershwin-desktop/gershwin-on-arch/releases/tag/continuous).
  
* GhostBSD users can try a [community preview ISO](https://www.ghostbsd.org/download)

* On an installed GhostBSD system, it is also possible to install Gershwin by installing following package:
```
 # pkg install gershwin-desktop
```

## Community Support

All community support tickets and feature requests should be created through our [community issue tracker](https://github.com/gershwin-desktop/issues).

For questions and other feedback, the [Github Discussions](https://github.com/orgs/gershwin-desktop/discussions) is a great place to reach out.  

## Contributing

Please see our help wanted section under our [GitHub project](https://github.com/orgs/gershwin-desktop/projects/1).

For resources to get started with development:

* http://developer.gnustep.org/
