# Adding an ISO flavor to the Gershwin desktop monorepo

This repo builds a Gershwin live ISO for several base OSes ("flavors") from one
tree. Adding a new flavor — e.g. **Artix** (Arch without systemd) — is a new
`targets/<flavor>/` directory plus two small workflows that reuse the shared
build → gate → publish machinery. This guide is the manual, no-tooling-required
procedure. (If you use Claude Code, the `add-iso-flavor` skill automates it.)

## How the monorepo is laid out

```
targets/<flavor>/            # the flavor's NATIVE live build + its config
.github/workflows/
  rc-<flavor>.yml            # release-candidate channel (builds default branches)
  dev-<flavor>.yml           # dev channel (builds `dev` source branches)
.github/actions/
  free-disk/                 # reclaim runner disk for a ~2 GB ISO
  screenshot-gate/           # boot the ISO in QEMU, OCR the desktop, screenshot it
  publish-continuous/        # roll the ISO + screenshot into the release, prune old
```

Every flavor has **two workflows** (channels):

| Channel | Builds | Tag | Title |
| --- | --- | --- | --- |
| **rc**  | default/`main` source branches | `<flavor>-rc`  | `<Display> (rc)`  |
| **dev** | `dev` source branches (fallback to default) | `<flavor>-dev` | `<Display> (dev)` |

Only the **build** is flavor-specific; the gate and publish are shared, so
"green means the same thing" on every flavor.

## The one rule: build in the flavor's own distro container

**Each Linux flavor builds its ISO inside a container of its own distribution,
using that distro's native live-media tooling** — never a reimplementation, and
never another distro's container:

| Flavor | Build environment | Native ISO tool |
| --- | --- | --- |
| debian    | stock `debian:latest` `--privileged`      | `live-build` (`lb config` + `lb build`) |
| devuan    | **custom** image `targets/devuan/ci/containers/Dockerfile` (Devuan repo + keyring + Devuan's `debootstrap`) | `debootstrap` + grub + xorriso |
| archlinux | stock `archlinux:latest` `--privileged`   | `mkarchiso` |
| freebsd / nextbsd | `vmactions/freebsd-vm`            | `makefs` → `mkuzip` → `mkisoimages.sh` |

Use a **stock** distro image where one exists; only add a `ci/containers/Dockerfile`
when the stock image lacks the tooling/keyring (as Devuan does). The container is
the per-flavor delta; the dominant cost is the shared Gershwin source compile, so
the container choice barely affects build time.

## The contract a flavor must honor

1. **ISO name** — write the ISO named
   `gershwin-on-<flavor>-<channel>-<UTC YYYYMMDDhhmmss>-<arch>.iso`,
   `arch` = `x86_64` or `aarch64` (never `amd64`/`arm64` in the filename).
   **No `.sha256` sidecar** (GitHub shows each asset's digest). The screenshot
   inherits the ISO's stem automatically at publish time.
2. **Boots to the desktop** — the ISO must boot to the Gershwin desktop on
   **x86_64 UEFI** in QEMU/OVMF so the shared gate can drive and screenshot it.
3. **Gershwin install** — inside the image's chroot/rootfs:
   ```sh
   git clone -b "${GERSHWIN_REF:-main}" https://github.com/gershwin-desktop/gershwin-developer.git /Developer
   /Developer/Library/Scripts/bootstrap.sh
   BRANCH="${GERSHWIN_BRANCH:-}" /Developer/Library/Scripts/checkout.sh
   cd /Developer && make install
   ```
   Honor `GERSHWIN_REF` (gershwin-developer clone ref) and `GERSHWIN_BRANCH`
   (source-repo branch for `checkout.sh`) so the **dev** channel works. Unset =
   the rc/default behaviour.
4. **admin account + auto-login** — the gate logs in as `admin` with no password:
   ```sh
   /Developer/... dscli init          # provisions the built-in admin (no password)
   ```
   and write `/Local/Library/Preferences/LoginWindow.plist`:
   ```
   { lastLoggedInUser = admin; lastSession = "/System/Library/Scripts/Gershwin.sh"; }
   ```
   Wire `loginwindow`, `dshelper`, `gdomap`, `dbus`, `avahi` to start under the
   flavor's init system (systemd unit / sysvinit / openrc / rc.d / launchd).
5. **XLibre, never Xorg.** Also drop a QEMU-friendly xorg snippet so the ISO
   renders under virtio-gpu / llvmpipe (see `targets/devuan/build.sh`'s
   `20-virtio-gpu.conf` for the pattern), or the screen stays black in the gate.
6. **Channel in the name** — honor `CHANNEL` (`rc`/`dev`) infixed into the ISO
   name. Unset = no infix.

## Step by step

1. **Pick the closest existing flavor as a template** by build tooling:
   - `live-build`/Debian-family → copy **debian**
   - `debootstrap`+grub, or needs a custom container → copy **devuan**
   - `mkarchiso`/Arch-family (incl. **Artix**) → copy **archlinux**
   - FreeBSD-derived → copy **freebsd** / **nextbsd**

2. **Create `targets/<flavor>/`** from that template: its native build
   (`build.sh` / `config/` / `profiledef.sh` + `airootfs/`), package lists, and
   a `ci/containers/Dockerfile` only if a stock image won't do. Adapt the distro
   specifics (mirrors, keyring, init wiring) and apply the contract above.

3. **Create `rc-<flavor>.yml` and `dev-<flavor>.yml`** by copying the template
   flavor's two workflows and changing:
   - `name:`, and the trigger `paths:` to
     `['targets/<flavor>/**', '.github/actions/**', '.github/workflows/<this-file>.yml']`
     (a flavor rebuilds only on its own target or a shared-action change — never
     another flavor's edit or a README-only change).
   - the gate step's `flavor:` input, and `publish-continuous`'s
     `tag: <flavor>-<channel>` and `title: <Display> (<channel>)`.
   - **rc** sets `CHANNEL=rc`; **dev** sets `CHANNEL=dev`, resolves the
     gershwin-developer ref (`dev` if it exists, else `main`) and passes
     `GERSHWIN_REF` + `GERSHWIN_BRANCH=dev`. How these are injected depends on the
     build environment: env exports (vmactions), `docker -e` (custom container),
     or prepend to the chroot install script (live-build hook / archiso
     `customize_airootfs.sh`). Copy the template's mechanism.
   - keep the **`cleanup` job** and `retention-days: 1` on the ISO upload (see
     "Artifact hygiene").

4. **Push and watch.** A flavor's build runs on push to `main`; it goes
   build → gate → publish → cleanup. Fix real failures; **re-run flakes**
   (transient distro-mirror errors; the gdomap menu race —
   `gershwin-desktop/gershwin-components#98`). Confirm the release has the
   channel-named `…-<channel>-<stamp>-<arch>.iso` + matching `.png`.

## Worked example — Artix

Artix is Arch without systemd, so start from **archlinux**:

- Copy `targets/archlinux/` → `targets/artix/` (`profiledef.sh`, `packages.x86_64`,
  `airootfs/`, `pacman.conf`, `efiboot/`, `syslinux/`).
- Build in an **Artix** container (`artixlinux/artixlinux`) with `mkarchiso` — or
  Artix's own live tooling — instead of `archlinux:latest`.
- Point `pacman.conf` at Artix repos (`system`/`world`/`galaxy`), plus the Arch
  `extra` overlay via Artix's `artix-archlinux-support` if you need Arch packages.
- **Init wiring is the real work**: replace every `systemctl enable …` in
  `airootfs/root/customize_airootfs.sh` with the equivalent for Artix's init
  (openrc / runit / s6) for `loginwindow`, `dshelper`, `gdomap`, `dbus`, `avahi`.
- Keep `dscli init` + the auto-login `LoginWindow.plist` unchanged.
- Add `rc-artix.yml` / `dev-artix.yml` from the archlinux pair; `flavor: artix`,
  tags `artix-rc`/`artix-dev`, titles `Artix (rc)`/`Artix (dev)`.

## Conventions reference

- **Filenames:** `gershwin-on-<flavor>-<channel>-<UTC YYYYMMDDhhmmss>-<arch>.{iso,png}`,
  arch `x86_64`/`aarch64`. Screenshot shares the ISO stem. No sha256 sidecars.
- **Releases:** tag `<flavor>-<channel>`, title `<Display> (<channel>)`, all
  `--prerelease`; body = inline screenshot + build-log link. Tags are **preserved**
  (publish uploads the new ISO, replaces the screenshot, prunes the old — never
  `--cleanup-tag`).
- **arch token vs flavor token:** use `archlinux`, not `arch` (collides with the
  CPU-arch token). Filenames use `x86_64`/`aarch64`; a distro's internal arch
  (dpkg `arm64`, FreeBSD `amd64`) maps to those.
- **Currently x86_64/amd64 only.** Dual-arch (aarch64) needs `publish-continuous`
  extended for two ISOs + one x86_64 screenshot.

## Artifact hygiene

The ISO artifact (~1.7 GB) is only a **job-handoff** copy — its permanent home is
the release. Each workflow therefore:
- sets `retention-days: 1` on the ISO upload (backstop), and
- has a **`cleanup` job** (`needs: [build, test, publish]`, `if: always()`,
  `permissions: actions: write`) that deletes the run's ISO + screenshot
  artifacts once publish has consumed them — keeping storage near zero.
- uploads `boot-artifacts` (frames/serial) **only on failure**.

Copy these verbatim from the template so a new flavor doesn't re-accumulate
tens of GB of artifacts.
