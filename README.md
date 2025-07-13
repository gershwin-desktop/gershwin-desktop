# gershwin-desktop
Gershwin is a desktop environment that brings forward and OS X-like user expereince.  It is currently available in GhostBSD as a community flavor.

![Gershwin-07112025](https://github.com/user-attachments/assets/9d3638c5-5fb1-49d6-9d17-1ea73d809548)

## Why Gershwin?

Having a Gershwin Desktop Environment community flavor hosted by GhostBSD encourages **growth of Objective-C and Cocoa-style application development**.  Where Gershwin comes into play is theming, packaging, putting together various settings, solving technical problems, modernizing applications as well providing new ones.  Last but not least we are making the effort to contribute back to GNUstep core libs.

## What does Gershwin offer?

It all starts with the Workspace.  A lot of changes were made to provide a good experience without the requirement of using WindowMaker.  When the session starts a File Viewer does not open.  A user can click System Disk on desktop or click Workspace Icon that shows running in Dock with proper app indicators.  Apps do not create app icons, or miniturized windows outside of the dock.  Instead apps are raised currently by clicking an app on the dock.  Additionally some deeper integration with non GNUstep apps is in place, and being actively enhanced.

## What’s NeXT?

Many more native applications, a tool to browse for them, and install them.  There is a second parallel stream of development happing to write new components, new applications, a new Dock, lower level integrations and frameworks.

## Installation

Prebuilt ISOs will be available soon via GhostBSD for testing and evaluation.  For now packages can be found in the unstable package repositories after installing GhostBSD.

For the adventurous grab the most recent GhostBSD Mate ISO, configure `/etc/pkg/GhostBSD.conf` to use the unstable repos:

```
GhostBSD_Unstable: {
  url: "https://pkg.ghostbsd.org/unstable/${ABI}/latest",
  enabled: yes
}

GhostBSD_Unstable_base: {
  url: "https://pkg.ghostbsd.org/unstable/${ABI}/base",
  enabled: yes
}%
```

Perform a full upgrade of the system, reboot, and then run the following command to install Gershwin:

```
sudo pkg install gershwin-desktop
```

After logging out of Mate you should ses a new Gershwin session in LightDM.

## Community Support

All community support tickets and feature requests should be created through our [community issue tracker](https://github.com/gershwin-desktop/issues).

## Contributing

Please see our help wanted section under our [GitHub project](https://github.com/orgs/gershwin-desktop/projects/1).

For resources to get started with development:

* http://developer.gnustep.org/

* https://github.com/gershwin-desktop/dev-config

## FAQ

* Will Gershwin ever support Wayland?  Yes.  GNUstep already has experimental wayland support.  
* Will Gershwin be Wayland only when that happens?  No
* What window manager is Gershwin using?  XFCE4-WM but a new window manager may be written from scratch at some point.
* Will a NeXT interface style be supported?  No.  A big reason for this project is to provide alternatives to that which already exist.
* Will Gershwin team ever consider provding an option for non Macintosh UX style?  Yes a Windows style layout option might be something we develop in the future in collaboration with GhostBSD.
