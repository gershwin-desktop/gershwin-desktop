---
name: add-iso-flavor
description: Use when adding a new base-OS flavor (e.g. Artix, Ubuntu, Fedora) to this Gershwin ISO monorepo, or when creating/fixing a flavor's rc or dev workflow. Encodes the per-distro-container build pattern, the target layout, the rc/dev channel workflows, the naming conventions, the gate contract, and the verify loop.
---

# Add / maintain an ISO flavor

The full human guide is **`docs/ADDING-A-FLAVOR.md`** — read it first; it is the
source of truth. This skill is the operational checklist and the gotchas.

## Core rules (do not violate)

1. **Build in the flavor's OWN distro container** using that distro's native
   live-media tool. Stock image where possible (`debian:latest` + live-build,
   `archlinux:latest` + mkarchiso); a custom `ci/containers/Dockerfile` only when
   the stock image lacks tooling/keyring (as Devuan does). BSD → `vmactions/freebsd-vm`.
   Never reimplement live-boot; never use another flavor's container.
2. **Two workflows per flavor**: `rc-<flavor>.yml` (default branches) and
   `dev-<flavor>.yml` (`dev` branches). Trigger `paths:` scoped to
   `['targets/<flavor>/**', '.github/actions/**', '.github/workflows/<this>.yml']`.
3. **Contract** (per `docs/ADDING-A-FLAVOR.md`): ISO named
   `gershwin-on-<flavor>-<channel>-<UTC YYYYMMDDhhmmss>-<arch>.iso` (arch =
   `x86_64`/`aarch64`, no sha256); boots to the Gershwin desktop on x86_64 UEFI;
   installs Gershwin via `git clone -b $GERSHWIN_REF gershwin-developer` →
   `bootstrap.sh` → `BRANCH=$GERSHWIN_BRANCH checkout.sh` → `make install`;
   `dscli init` + auto-login `LoginWindow.plist`; XLibre + a virtio-gpu xorg
   snippet; honors `CHANNEL`, `GERSHWIN_REF`, `GERSHWIN_BRANCH`.
4. **Artifact hygiene**: keep the `cleanup` job + `retention-days: 1` on the ISO
   upload; `boot-artifacts` only `if: failure()`. The ISO's home is the release.

## How to add a flavor

1. Pick the closest template flavor by tooling (Arch-family incl. **Artix** →
   `archlinux`; live-build → `debian`; debootstrap/custom-container → `devuan`;
   FreeBSD-derived → `freebsd`/`nextbsd`).
2. `cp -R targets/<template>/ targets/<flavor>/`; adapt distro specifics
   (container image, mirrors/keyring, **init wiring** — the real work for
   non-systemd distros like Artix: openrc/runit/s6 instead of `systemctl enable`).
3. Copy the template's `rc-*.yml` + `dev-*.yml`; update `name`, `paths`, the gate
   `flavor:`, `tag: <flavor>-<channel>`, `title: <Display> (<channel>)`, and the
   channel/branch injection (env exports / `docker -e` / prepend-to-install-script
   — copy the template's mechanism; rc→`CHANNEL=rc`, dev→resolve gershwin-developer
   ref + `GERSHWIN_BRANCH=dev` + `CHANNEL=dev`).
4. Validate before pushing: `python3 -c "import yaml,glob;[yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]"` and `sh -n` any build.sh.

## Adding an ARCH to an existing flavor

Not the same job as adding a flavor. Do it as a **matrix inside the flavor's
existing two workflows** — do not add `rc-<flavor>-<arch>.yml`; rule 2 above is
two workflows per flavor, full stop. Matrix `build` and `test` over
`{arch, runner, ...}` with `fail-fast: false` so one arch cannot mask the other.

- **`targets/*/build.sh` may already be arch-aware.** nextbsd's was: it maps
  `amd64|x86_64 -> x86_64` / `arm64|aarch64 -> aarch64` for the release label,
  keeps `aarch64` for the pkg ABI, and already skips `cdboot` (BIOS-only) so
  arm64 ISOs come out UEFI-only. Read it before writing anything.
- **Artifact names inside a shared composite action are global per run.** Two
  matrix legs both uploading `desktop-screenshot` fail the job outright.
  `screenshot-gate` therefore takes `artifact-suffix` (default `''`, so
  single-arch flavors are untouched); a multi-arch caller MUST pass it.
- **Then fix the cleanup filter.** It keys off the literal name — once artifacts
  are suffixed it must be `select(.name | startswith("boot-artifacts") | not)`,
  or `boot-artifacts-<arch>` gets deleted on failure, which is exactly when you
  need it.
- **One screenshot per release.** Every arch writes the same
  `gershwin-on-<flavor>.png`, so merging arches into one directory is a coin
  toss. Pick one arch's frame for the release body on purpose; the others stay
  in their own artifacts as gate evidence.

## arm64 specifics (learned the hard way)

- **Use `runs-on: ubuntu-24.04-arm` for both build and gate.** Both need KVM:
  the gate boots an entire desktop and the build does a world+packages run, and
  neither fits its timeout under TCG. vmactions' README says to stay on
  `ubuntu-latest` with `arch: aarch64` and warns against arm runners — that
  guidance is about their own VM tuning and predates free arm64 runners; it is
  not a reason to emulate a 240-minute build.
- **QEMU `virt` is not q35.** Porting the gate needed four changes, each of
  which is a silent hang if missed:
  - no IDE, so `-cdrom` is wrong: attach the ISO as
    `-drive if=none,...,media=cdrom` + `-device virtio-blk-pci,bootindex=0`;
  - no PS/2, so monitor `sendkey` reaches nothing without
    `-device qemu-xhci -device usb-kbd` — and the whole gate is sendkey-driven;
  - no `-bios`: UEFI is two pflash banks, and the vars bank must be a writable
    **copy** of `AAVMF_VARS.fd` (QEMU demands the exact declared size);
  - no `-vga std`: use `-device virtio-gpu-pci`.
- **Arch tokens differ by layer, deliberately.** Workflow/matrix and
  `TARGET_ARCH` use `amd64`/`arm64`; pkg ABI uses `aarch64`; ISO filenames use
  `x86_64`/`aarch64` (rule: never put `amd64`/`arm64` in a filename).

## Verify loop

- Push to `main`; the flavor's build triggers (build → gate → publish → cleanup).
  `rc-all` / `dev-all` fan out to every flavor on demand and discover them from
  the Actions API — a new flavor is picked up automatically, nothing to register.
  Watch with `gh run list --workflow <wf>.yml` / `gh run view <id> --json conclusion,jobs`.
- **Changes to shared `build.sh`/actions are no-ops for rc when the new env vars
  are unset** — a green rc proves the plumbing is safe.
- **Re-run flakes, don't "fix" them** (`gh run rerun <id>`): transient distro
  mirror errors (Arch pacstrap "download library error"), and the intermittent
  **gdomap menu race** (desktop up but `Workspace` menu absent →
  `System Disk=1 Workspace=0` → gate `FAIL(1)`; tracked in
  `gershwin-desktop/gershwin-components#98`, channel-independent).
- Confirm success: release has `…-<channel>-<stamp>-<arch>.iso` + matching `.png`,
  and `gh api /repos/<repo>/actions/artifacts` stays near 0 (cleanup working).

## Do NOT

- Do not commit temp/debug files into the repo tree (download to a scratch dir).
- Do not add `.sha256` sidecars or `--cleanup-tag`.
- Do not put the CPU arch (`amd64`/`arm64`) in filenames — use `x86_64`/`aarch64`.
- Do not build a Linux flavor on bare `ubuntu-latest` with cross-distro hacks —
  use its own container.
