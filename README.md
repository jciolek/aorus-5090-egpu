# Manjaro-Patched `nvidia-open-dkms` Build Pipeline

If you run Manjro and have Gigabyte Aorus RTX 5090 AI Box, which cannot handle any work, because it crashes your machine,
you came to the right place.

If you want to make sure that this repo is what you need, have a look at [this GitHub issue](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979).

This repo is a Manjaro adaptation of [apnex/nvidia-driver-injector](https://github.com/apnex/nvidia-driver-injector),
which first demonstrated that this set of driver and system patches actually works.

## Overview

There is a lot of detailed information about the issue in the driver-injector repository and the GitHub issue linked above.
I am not going to repeat all of that here, instead I am going to provide a high level overview.

The nvidia driver version 610.43.02 has much improved in terms of support for an RTX50xx connected over Thunderbolt. It does not require any patches in order to make the GPU reliably available at least in CUDA capacity.

The problems originating from Thunderbolt link negotiation still persist. This requires a set of system patches, namely:

* setting link speed
* loading nvidia modules only **after** the link speed has been established

To ensure the nvidia modules are not loaded automatically, the are blacklisted and applied fake install method `/bin/false`.
For setting link speed and loading the nvidia modules afterwards we use a systemd service.
To drop support for sound on GPU we use udev rules.

The install tool patches up configuration (see below).

The uninstall tool tries to restore the system state to what it was prior to the installation.

### Supported distributions

The tooling auto-detects the host's initramfs system:

* **Arch / Manjaro** — uses `mkinitcpio` and `/etc/mkinitcpio.conf`.
* **Debian / Ubuntu** — uses `update-initramfs` and `/etc/initramfs-tools/modules`.

Everything else (GRUB cmdline, `modprobe.d` policy, the systemd service and the
helper binaries) is identical across distributions. You can force a backend with
`INITRAMFS_BACKEND=mkinitcpio` or `INITRAMFS_BACKEND=initramfs-tools` if detection
guesses wrong.

**This works on my machine. It has not been tested on anyone else's.**

## Install

```bash
./install.sh
```

This does the following:

- Removes conflicting NVIDIA modules from the initramfs module list
  (`/etc/mkinitcpio.conf` on Arch/Manjaro, `/etc/initramfs-tools/modules` on Debian/Ubuntu)
- Rewrites `/etc/modprobe.d/*.conf` to disable conflicting NVIDIA modules
- Rewrites `/etc/default/grub` with correct kernel parameters for the GPU bridge
- Installs `aorus-bridge` and `aorus-modules` binaries to `/usr/local/bin`
- Regenerates the initramfs (`mkinitcpio -P` or `update-initramfs -u`) and GRUB configs if they were changed

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

- Restores the initramfs module list (`mkinitcpio.conf` or `initramfs-tools/modules`), `grub`, and `modprobe.d` files from their `.aorus.*` backups
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

This will only show what would be done, without enacting any changes.

