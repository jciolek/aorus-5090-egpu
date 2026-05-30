# Patch Audit

Audit of the active downstream patch stack applied after the upstream
Manjaro open-kernel patch series.
`patches/manifest` is the source of truth for downstream patch inclusion and
apply order across all three downstream phases.

## Base Phase

| Patch | Scope | Notes |
|---|---|---|
| `C1-kbuild-version-mk.patch` | build system | Derives `NV_VERSION_STRING` from `version.mk` so Kbuild does not carry a hard-coded version literal. |
| `C2-aer-internal-unmask.patch` | kernel-open PCIe error handling | Adds the injector's AER internal unmask behavior used by the recovery path. |
| `C3-gpu-lost-retry.patch` | kernel-open GPU-lost handling | Adds the retry path for transient GPU-lost behavior. |
| `C4-err-handlers-scaffold.patch` | kernel-open PCIe error-handler plumbing | Adds the scaffold that the later recovery behavior builds on. |
| `E1-egpu-detection.patch` | kernel-open external-GPU detection | Uses kernel PCI transport classification to detect Thunderbolt and USB4 attached external GPUs. |
| `C5-crash-safety.patch` | kernel-open crash safety | Adds dead-bus short-circuiting and disconnect propagation that reduce host stalls after bus loss. |

## Addon Phase

| Patch | Scope | Notes |
|---|---|---|
| `A1-pcie-primitives.patch` | kernel-open shared PCIe helpers | Adds shared WPR2, AER, DPC, and topology-walk primitives used by the addon recovery path. |
| `A2-bus-loss-watchdog.patch` | kernel-open watchdog | Adds the addon watchdog that detects runtime bus loss on active DMA paths. |
| `A3-recovery.patch` | kernel-open recovery | Adds the addon PCIe recovery state machine and reset path. |
| `A4-close-path-telemetry.patch` | kernel-open telemetry | Adds close-path lifecycle telemetry used by the injector stack. |
| `A5-version-and-toggles.patch` | kernel-open versioning and toggles | Adds the injector addon version-and-toggle layer exactly as vendored. |

## Local Phase

| Patch | Scope | Notes |
|---|---|---|
| `L1-no-suffix-version-string.patch` | runtime version compatibility | Final repo-local override that resets `NVIDIA_VERSION` to upstream `595.71.05` after vendored addon `A5`, keeping firmware lookup and module cross-checks aligned with stock `nvidia-utils`. |
