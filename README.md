# Manjaro-Patched `nvidia-open-dkms` Build Pipeline

If you run Manjro and have Gigabyte Aorus RTX 5090 AI Box, which cannot handle any work, because it crashes your machine,
you came to the right place.

If you want to make sure that this repo is what you need, have a look at [this GitHub issue](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979).

This repo is a Manjaro adaptation of [apnex/nvidia-driver-injector](https://github.com/apnex/nvidia-driver-injector),
which first demonstrated that this set of driver and system patches actually works.

## Overview

There is a lot of detailed information about the issue in the driver-injector repository and the GitHub issue linked above.
I am not going to repeat all of that here, instead I am going to provide a high level overview.

The nvidia drivers version 595.75.01 have a few problems with an RTX50xx connected over Thunderbolt.
In order to make the GPU reliably available at least in CUDA capacity, the driver requires a few patches.

Another set of problems originates from Thunderbolt link negotiation. This requires a set of system patches, namely:

* setting link speed
* dropping support for unnecessary secondary functionality of the GPU, e.g. sound.
* loading nvidia modules only **after** the link speed has been established
* not loading nvidia_drm nor nvidia_modeset at all

To ensure the nvidia modules are not loaded automatically, the are blacklisted and applied fake install method `/bin/false`.
For setting link speed and loading the nvidia modules afterwards we use a systemd service.
To drop support for sound on GPU we use udev rules.

The build tool in this repository builds a patched local `nvidia-open-dkms` package from the official Manjaro packaging tree.
It fetches the matching upstream Manjaro commit, rewrites the `PKGBUILD` into a dedicated local
`nvidia-open-dkms` package, preserves every upstream patch the fetched `prepare()` flow applies,
then applies three layers of vendor-local patches (base, addon, local) in order. Only `nvidia-open-dkms` is build locally -
it is compatible with other packages from upstrem nvidia suite.

The install tool patches up configuration (see below).

The uninstall tool tries to restore the system state to what it was prior to the installation.

**This works on my machine. It has not been tested on anyone else's.**

## Build

Builds the patched `nvidia-open-dkms` package file:

```bash
./build.sh
```

This clones the official Manjaro `nvidia-utils` repo, rewrites its `PKGBUILD`,
runs `makepkg`, and drops `nvidia-open-dkms-*.pkg.tar.zst` in this directory.

**You have to install the package yourself, for example:**

`pacman -U ./nvidia-open-dkms-595.71.05-2-x86_64.pkg.tar.zst`

You can also specify a target version:

```bash
MANJARO_TARGET_VERSION=600.80.03-1 ./build.sh
```

## Install

Installs the rebuilt package and patches your system configuration:

```bash
./install.sh
```

This does the following:

- Rewrites `/etc/mkinitcpio.conf` to remove conflicting NVIDIA modules
- Rewrites `/etc/modprobe.d/*.conf` to disable conflicting NVIDIA modules
- Rewrites `/etc/default/grub` with correct kernel parameters for the GPU bridge
- Installs `aorus-bridge` and `aorus-modules` binaries to `/usr/local/bin`
- Installs udev rules, systemd service files, and modprobe config
- Regenerates `mkinitcpio` and GRUB configs if they were changed

**Installation creates backup files** (marked with `.aorus.*` suffix) for all files it modifies
and for all files it installs. **`uninstall.sh` uses these backups to reverse the changes**.

If `mkinitcpio` or GRUB configs change during installation, a reboot is required.

### Options

Dry run (no changes, just prints what would happen):

```bash
sudo ./install.sh --dry-run
```

## Uninstall

Reverses everything `install.sh` did:

```bash
./uninstall.sh
```

This does the following:

- Restores `mkinitcpio.conf`, `grub`, and `modprobe.d` files from their `.aorus.*` backups
- Removes files installed by this repo (those without backups)
- Disables the `aorus.service` systemd unit
- Restores the live bridge state and unloads NVIDIA modules

**It relies on the backup files created by `install.sh`.**
If a backup is missing for a managed file, uninstall tries to remove the file entirely
(instead of restoring).

If managed configs were dirty, a reboot is required.

### Options

Dry run:

```bash
sudo ./uninstall.sh --dry-run
```

## Patch layers

Patches are applied in this order during `makepkg`:

1. **Upstream** - patches from the fetched Manjaro `prepare()` flow for `nvidia-open-dkms`
2. **Base** (`patches/base/`) - vendored injector core patches (always applied)
3. **Addon** (`patches/addon/`) - vendored injector extra patches (always applied)
4. **Local** (`patches/local/`) - repo-owned override patches

The `patches/manifest` file controls which patches are included and their order.

## Version updates

When Manjaro ships a new `nvidia-open-dkms` version, run `build.sh` again.
If an upstream patch, the vendor base phase, the vendor addon phase, or a local
override patch fails on the new version, that is expected maintenance work.
