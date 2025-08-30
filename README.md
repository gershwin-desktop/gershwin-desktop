# gershwin-desktop
Gershwin is a desktop environment with an OS X-like user experience. It is currently available as a GhostBSD community flavor.

![Gershwin-07112025](https://github.com/user-attachments/assets/9d3638c5-5fb1-49d6-9d17-1ea73d809548)

## Why Gershwin?

Having a Gershwin Desktop Environment community flavor hosted by GhostBSD encourages **growth of Objective-C and Cocoa-style application development**.  Where Gershwin comes into play is theming, packaging, putting together various settings, solving technical problems, modernizing applications as well providing new ones.  Last but not least we are making the effort to contribute back to GNUstep core libs.

## What does Gershwin offer?

It all starts with the Workspace.  A lot of changes were made to provide a good experience without the requirement of using WindowMaker.  When the session starts a File Viewer does not open.  A user can click System Disk on desktop or click Workspace Icon that shows running in Dock with proper app indicators.  Apps do not create app icons, or miniturized windows outside of the dock.  Instead apps are raised currently by clicking an app on the dock.  Additionally some deeper integration with non GNUstep apps is in place, and being actively enhanced.

## What’s NeXT?

Many more native applications, a tool to browse for them, and install them.  There is a second parallel stream of development happing to write new components, new applications, a new Dock, lower level integrations and frameworks.

## Installation

Prebuilt ISOs will be available soon via GhostBSD for testing and evaluation.  For now packages can be found in the unstable package repositories after installing GhostBSD.

For the truly adventerous here are the [GhostBSD Unstable Instructions](https://github.com/gershwin-desktop/gershwin-desktop/wiki/GhostBSD-Unstable-Instructions) to try out the work in progress.

## Community Support

All community support tickets and feature requests should be created through our [community issue tracker](https://github.com/gershwin-desktop/issues).

For questions, and other feedback the [Github Discussions](https://github.com/orgs/gershwin-desktop/discussions) is a great place to reach out.  

## Contributing

Please see our help wanted section under our [GitHub project](https://github.com/orgs/gershwin-desktop/projects/1).

For resources to get started with development:

* http://developer.gnustep.org/

* https://github.com/gershwin-desktop/dev-config

## FAQ

* Will Gershwin ever support Wayland?  GNUstep has experimental wayland support and we use it's core libs.   
* Will Gershwin ever be Wayland only?  There will be no effort to make Gershwin wayland only since we use core libs from GNUstep.
* What window manager is Gershwin using?  XFCE4-WM but this may be replaced by soon by uroswm a native window manager based on xcbkit that is being fixed up to be integrated with Gershwin.  
* Will Gershwin team ever consider provding an option for non Macintosh UX style?  Yes a Windows style layout option might be something we develop in the future in collaboration with GhostBSD.
