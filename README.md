# Manjaro-Patched `nvidia-open-dkms` Build Pipeline

This repository builds a patched local `nvidia-open-dkms` package from the
official Manjaro packaging tree.
The wrapper fetches the matching upstream packaging commit,
rewrites the staged `PKGBUILD` into a dedicated local `nvidia-open-dkms`
package,
preserves every upstream patch that the fetched Manjaro `prepare()` flow applies to `${_pkg_open}`,
then applies this repo's vendored injector `patches/base` phase,
followed by this repo's vendored injector `patches/addon` phase,
and finally this repo's `patches/local` override phase.
Within the downstream phases,
`patches/manifest` is the source of truth for which vendored or repo-local patches are included
and the order they are applied.

## Build

```bash
./build.sh
```

## Install

```bash
sudo pacman -U ./nvidia-open-dkms-*.pkg.tar.zst
```

## Version updates

When a new Manjaro NVIDIA package version appears, rerun the wrapper.
If an upstream open-kernel patch, the vendored injector base phase,
the vendored injector addon phase, or the repo-local override phase fails on the new version,
that is expected downstream maintenance work.

## Patch layers

- upstream patch files selected from the fetched Manjaro `prepare()` flow for `${_pkg_open}`
- repo `patches/base/` - vendored injector base phase,
  with inclusion and order declared by `patches/manifest`
- repo `patches/addon/` - vendored injector addon phase,
  with inclusion and order declared by `patches/manifest`
- repo `patches/local/` - repo-owned final override phase,
  with inclusion and order declared by `patches/manifest`

Only `nvidia-open-dkms` is built locally.
