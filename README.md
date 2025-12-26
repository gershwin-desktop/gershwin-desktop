# gershwin-desktop
Gershwin is a desktop environment based on GNUstep with an early Mac OS X-like user experience. 

<img width="1918" height="1079" alt="Screenshot 2025-12-25 at 11 32 34 PM" src="https://github.com/user-attachments/assets/c28184d2-27e9-4499-aadd-3e6dc7d6e3dc" />

## Why Gershwin?

Gershwin Desktop Environment aims to encourage **growth of Objective-C and Cocoa-style application development** by showcasing a fully native GNUstep environment that integrates non native applications.  

* Gershwin can be built from source code in less than a few minutes on even low spec virtual machines with 1 GB memory 1 CPU
* The entire system only consumes including Window Manager only consumes under 50MB of storage
* Gershwin is completely self contained from the underlying operating system
* Local Users and Local Applications are kept seperate from Network Users and Network Applications and System Applications
* Users can install Application bundles without root credentials in the Users folder
* Applications built using Gershwin and it's underlying GNUstep tools can run on other many operating systems including Windows

## What does Gershwin offer?

Gershwin offers Workspace, Terminal, TextEdit, System Preferences, a native Window Manager for X11 apps, Global Menu server for GNUstep/X11 apps, and more.  

## Installation and testing

* Gershwin can be installed in under a few minutes by using [gershwin-build](https://github.com/gershwin-desktop/gershwin-build).

* Testers can try a [gershwin-on-debian live iso](https://github.com/gershwin-desktop/gershwin-on-debian/releases/tag/continuous).

## Community Support

All community support tickets and feature requests should be created through our [community issue tracker](https://github.com/gershwin-desktop/issues).

For questions and other feedback, the [Github Discussions](https://github.com/orgs/gershwin-desktop/discussions) is a great place to reach out.  

## Contributing

Please see our help wanted section under our [GitHub project](https://github.com/orgs/gershwin-desktop/projects/1).

For resources to get started with development:

* http://developer.gnustep.org/

## FAQ

* Will Gershwin ever support Wayland?  GNUstep has experimental Wayland support and we use it's core libs.   
* Will Gershwin ever be Wayland only?  There will be no effort to make Gershwin Wayland only since we use core libs from GNUstep which continue to support X11.
