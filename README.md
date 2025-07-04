# gershwin-desktop
Gershwin is a desktop environment that brings forward and OS X-like user expereince.  It is available exclusively in GhostBSD as a community flavor.

![Gershwin-07042025](https://github.com/user-attachments/assets/33a0a7bd-8f2b-4d50-ac2c-1d8a8553e4d8)

## Why Gershwin?

Having a Gershwin Desktop Environment community flavor provided by GhostBSD encourages **growth of Objective-C and Cocoa-style application development**t.  Where Gershwin comes into play is theming, packaging, putting together various settings, solving technical problems, modernizing applications as well providing new ones.  

## What does modernization mean?

It all starts with the Workspace.  A lot of changes were made to provide a good experience without the requirement of using WindowMaker.  When the session starts a File Viewer does not open.  A user can click System Disk on desktop or click Workspace Icon that shows running in Dock with proper app indicators.  Apps do not create app icons, or miniturized windows outside of the dock.  Instead apps are raised currently by clicking an app on the dock.  In System Preferences we only show are themes.  We ship a modern light, and dark theme based on forks with modifications.  We make apps like Terminal have a right side scrollbar, and TextEdit open a new document when launch.  

## What’s NeXT?

We have integration coming to make non GNUstep apps and GNUstep apps use the same global menu system.  We also plan to integrate dock status icon support, and other related features.  We will further integrate GhostBSD solutions for Backup Station, Update Station, Software Station as part of our collaboration with GhostBSD.  Beyond this there is a second parallel stream of development happing to write new components, a new Dock, a Workspace replacement, a System Preferences replacement, a File Manager that leverages ZFS, lower level integrations and frameworks.

## Installation

Prebuilt ISOs will be available via GhostBSD for testing and evaluation.

## Community Support

All community support tickets and feature requests should be created through our community issue tracker here.

## Contributing

Please see our help wanted section under our GitHub project here, and look for help wanted, good first issues.

For resources to get started with development:

* http://developer.gnustep.org/

* https://github.com/gershwin-desktop/dev-config (each repo contains a copy)
Vscode or neovim can be used with these for linting

* From GhostBSD pkg install gershwin-developer-tools (TODO make the metapkg)
