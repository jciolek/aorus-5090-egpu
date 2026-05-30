# Overview

This repo's main purpose is rebuilding Manjaro upstream nvidia-open-dkms package
with patches, helping to run NVIDIA RTX 5090 eGPU with the current buggy driver.

The inspiration for this work is [NVIDIA driver injector](https://github.com/apnex/nvidia-driver-injector/tree/main), which is mentioned in the [GitHub thread](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979#issuecomment-4514103926)

# Setup

Once the package is built and installed, there are a few more things that need to be configured.

## Modules

Nvidia needs to be blacklisted:

`/etc/modprode.d/nvidia.conf`:

```
blacklist nvidia
blacklist nvidia_modeset
blacklist nvidia_uvm
blacklist nvidia_drm

install nvidia /bin/false
install nvidia_modeset /bin/false
install nvidia_uvm /bin/false
install nvidia_drm /bin/false

options nvidia_drm modeset=0 fbdev=0
options nvidia NVreg_DynamicPowerManagement=0 NVreg_EnableS0ixPowerManagement=0 NVreg_PreserveVideoMemoryAllocations=0 NVreg_TbEgpuRecoverEnable=1 NVreg_RegistryDwords="RmForceExternalGpu=1"
```

Of course, the nvidia modules cannot be loaded in initramfs either, so check the MODULES directive in `/etc/mkinitcpio.conf`


## UDEV

It's best not to strain the RTX, so audio should not be allowed to be bound.

`/etc/udev/rules.d/80-nvidia-egpu-audio.rules`


```
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{device}=="0x22e8", \
  ATTR{driver_override}="nvidia-egpu-audio-disabled", \
  RUN+="/bin/sh -c '[ -L /sys/bus/pci/devices/%k/driver ] && echo %k > /sys/bus/pci/devices/%k/driver/unbind || true'"
```

## Bridge link cap

The bridge link cap needs to be set, see this file `nvidia-egpu-bridge-link-cap`. This needs to be run every time the machine boots.


## Modules (again)

Finally, the modules need to be force-loaded. See `nvidia-egpu-load-modules`.
