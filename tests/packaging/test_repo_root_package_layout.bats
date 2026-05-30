#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
legacy_patch_layer_dir_name='patches-'"local"
legacy_gate_config_basename='nvidia-egpu-gates.'"conf"

assert_exists() {
    local path="$1"
    [[ -e "$path" ]] || {
        printf 'expected path to exist: %s\n' "$path" >&2
        return 1
    }
}

assert_not_exists() {
    local path="$1"
    [[ ! -e "$path" ]] || {
        printf 'expected path to be absent: %s\n' "$path" >&2
        return 1
    }
}

assert_contains() {
    local needle="$1"
    local file="$2"
    grep -Fq -- "$needle" "$file" || {
        printf 'expected to find %s in %s\n' "$needle" "$file" >&2
        return 1
    }
}

assert_not_contains() {
    local needle="$1"
    local file="$2"
    if grep -Fq -- "$needle" "$file"; then
        printf 'expected %s to be absent from %s\n' "$needle" "$file" >&2
        return 1
    fi
}

assert_not_line() {
    local needle="$1"
    local file="$2"
    if grep -Fxq -- "$needle" "$file"; then
        printf 'expected exact line %s to be absent from %s\n' "$needle" "$file" >&2
        return 1
    fi
}

assert_not_matches() {
    local pattern="$1"
    local file="$2"
    if rg -n --pcre2 -- "$pattern" "$file" >/dev/null; then
        printf 'expected pattern %s to be absent from %s\n' "$pattern" "$file" >&2
        return 1
    fi
}

assert_line_order() {
    local first_pattern="$1"
    local second_pattern="$2"
    local file="$3"
    local first_line second_line

    first_line="$(grep -n -F -m1 -- "$first_pattern" "$file" || true)"
    second_line="$(grep -n -F -m1 -- "$second_pattern" "$file" || true)"

    first_line="${first_line%%:*}"
    second_line="${second_line%%:*}"

    if [[ -z "$first_line" || -z "$second_line" ]]; then
        printf 'could not compare order in %s: %s / %s\n' "$file" "$first_pattern" "$second_pattern" >&2
        return 1
    fi

    if (( first_line >= second_line )); then
        printf 'unexpected order in %s: %s should appear before %s\n' \
            "$file" "$first_pattern" "$second_pattern" >&2
        return 1
    fi
}

test_root_package_workspace_exists() {
    assert_exists "${repo_root}/build-local-package.sh"
    assert_exists "${repo_root}/patches/manifest"
    assert_exists "${repo_root}/patches/base/C1-kbuild-version-mk.patch"
    assert_exists "${repo_root}/patches/base/C5-crash-safety.patch"
    assert_exists "${repo_root}/patches/addon/A1-pcie-primitives.patch"
    assert_exists "${repo_root}/patches/addon/A5-version-and-toggles.patch"
    assert_exists "${repo_root}/patches/local/L1-no-suffix-version-string.patch"
    assert_exists "${repo_root}/patch-audit.md"
    assert_not_exists "${repo_root}/patches/C1-kbuild-version-mk.patch"
    assert_not_exists "${repo_root}/patches/C5-crash-safety.patch"
    assert_not_exists "${repo_root}/patches/A1-pcie-primitives.patch"
    assert_not_exists "${repo_root}/patches/L1-no-suffix-version-string.patch"
}

test_repo_patch_manifest_declares_base_then_addon_then_local_order() {
    local manifest="${repo_root}/patches/manifest"

    rg -n --pcre2 '^\s*C1-kbuild-version-mk\s+base\s+-\s+fork:c1-kbuild-version-mk\s*$' "$manifest" >/dev/null || {
        printf 'expected semantic manifest row for C1 base patch in %s\n' "$manifest" >&2
        return 1
    }
    rg -n --pcre2 '^\s*C5-crash-safety\s+base\s+-\s+fork:c5-crash-safety\s*$' "$manifest" >/dev/null || {
        printf 'expected semantic manifest row for C5 base patch in %s\n' "$manifest" >&2
        return 1
    }
    rg -n --pcre2 '^\s*A1-pcie-primitives\s+addon\s+-\s+fork:a1-pcie-primitives\s*$' "$manifest" >/dev/null || {
        printf 'expected semantic manifest row for A1 addon patch in %s\n' "$manifest" >&2
        return 1
    }
    rg -n --pcre2 '^\s*A5-version-and-toggles\s+addon\s+-\s+fork:a5-version-and-toggles\s*$' "$manifest" >/dev/null || {
        printf 'expected semantic manifest row for A5 addon patch in %s\n' "$manifest" >&2
        return 1
    }
    rg -n --pcre2 '^\s*L1-no-suffix-version-string\s+local\s+-\s+repo:l1-no-suffix-version-string\s*$' "$manifest" >/dev/null || {
        printf 'expected semantic manifest row for L1 local patch in %s\n' "$manifest" >&2
        return 1
    }
    assert_line_order 'C1-kbuild-version-mk' 'C5-crash-safety' "$manifest"
    assert_line_order 'C5-crash-safety' 'A1-pcie-primitives' "$manifest"
    assert_line_order 'A1-pcie-primitives' 'A5-version-and-toggles' "$manifest"
    assert_line_order 'A5-version-and-toggles' 'L1-no-suffix-version-string' "$manifest"
    assert_contains '-NVIDIA_VERSION = 595.71.05-aorus.14' "${repo_root}/patches/local/L1-no-suffix-version-string.patch"
    assert_contains '+NVIDIA_VERSION = 595.71.05' "${repo_root}/patches/local/L1-no-suffix-version-string.patch"
}

test_root_no_longer_owns_upstream_package_files() {
    assert_not_exists "${repo_root}/PKGBUILD"
    assert_not_exists "${repo_root}/mhwd-nvidia"
    assert_not_exists "${repo_root}/nvidia-drm-outputclass.conf"
    assert_not_exists "${repo_root}/nvidia-utils.sysusers"
    assert_not_exists "${repo_root}/nvidia.rules"
    assert_not_exists "${repo_root}/systemd-homed-override.conf"
    assert_not_exists "${repo_root}/systemd-suspend-override.conf"
    assert_not_exists "${repo_root}/nvidia-sleep.conf"
    assert_not_exists "${repo_root}/systemd.patch"
    assert_not_exists "${repo_root}/50-nvidia-cuda-disable-perf-boost.conf"
    assert_not_exists "${repo_root}/0002-Add-IBT-support.patch"
    assert_not_exists "${repo_root}/limit-vram-usage"
    assert_not_exists "${repo_root}/cuda-no-stable-perf-limit"
    assert_not_exists "${repo_root}/nvidia-utils.install"
}

test_nested_package_workspace_is_removed() {
    assert_not_exists "${repo_root}/packaging/manjaro/nvidia-open-dkms/PKGBUILD"
    assert_not_exists "${repo_root}/packaging/manjaro/nvidia-open-dkms/build-local-package.sh"
    assert_not_exists "${repo_root}/packaging/manjaro/nvidia-open-dkms/patches"
}

test_runtime_stack_is_archived() {
    assert_exists "${repo_root}/archive/runtime-stack/apply.sh"
    assert_exists "${repo_root}/archive/runtime-stack/remove.sh"
    assert_exists "${repo_root}/archive/runtime-stack/reset.sh"
    assert_exists "${repo_root}/archive/runtime-stack/status.sh"
    assert_exists "${repo_root}/archive/runtime-stack/etc"
    assert_exists "${repo_root}/archive/runtime-stack/usr"
    assert_exists "${repo_root}/archive/runtime-stack/lib"
    assert_exists "${repo_root}/archive/runtime-stack/tools"

    assert_not_exists "${repo_root}/apply.sh"
    assert_not_exists "${repo_root}/remove.sh"
    assert_not_exists "${repo_root}/reset.sh"
    assert_not_exists "${repo_root}/status.sh"
    assert_not_exists "${repo_root}/etc"
    assert_not_exists "${repo_root}/usr"
    assert_not_exists "${repo_root}/lib"
    assert_not_exists "${repo_root}/tools"
}

test_runtime_docs_are_archived_but_superpowers_docs_remain_active() {
    assert_exists "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_exists "${repo_root}/archive/runtime-stack/docs"
    assert_exists "${repo_root}/docs/superpowers"
}

test_archived_build_paths_point_at_live_patch_series() {
    assert_contains 'PATCH_DIR="$LIVE_REPO_ROOT/patches"' "${repo_root}/archive/runtime-stack/tools/build-patched-driver.sh"
    assert_contains 'sudo ./archive/runtime-stack/tools/build-patched-driver.sh' "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_contains '$ sudo ./archive/runtime-stack/status.sh | tail -3' "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_contains 'sudo ./archive/runtime-stack/apply.sh' "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_contains 'sudo ./archive/runtime-stack/status.sh' "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_contains 'sudo ./archive/runtime-stack/remove.sh' "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_contains 'The archived runtime stack ships four top-level entrypoints under' "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_contains '| `reset.sh` | Recover from a degraded state without rebooting. |' "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_contains 'sudo ./archive/runtime-stack/reset.sh --probe' "${repo_root}/archive/runtime-stack/reset.sh"
    assert_contains 'sudo /path/to/repo/archive/runtime-stack/apply.sh' "${repo_root}/archive/runtime-stack/remove.sh"
    assert_contains 'sudo /path/to/repo/archive/runtime-stack/tools/build-patched-driver.sh' "${repo_root}/archive/runtime-stack/remove.sh"

    assert_not_matches '(?<!archive/runtime-stack/)\./status\.sh(?:\s|`|\||$)' "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_not_matches '(?<!archive/runtime-stack/)\./apply\.sh(?:\s|`|$)' "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_not_matches '(?<!archive/runtime-stack/)\./remove\.sh(?:\s|`|$)' "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_not_matches '(?<!archive/runtime-stack/)\./tools/build-patched-driver\.sh(?:\s|`|$)' "${repo_root}/archive/runtime-stack/README.runtime-stack.md"
    assert_not_line 'red "  - To re-install:    sudo ./apply.sh && sudo ./tools/build-patched-driver.sh"' "${repo_root}/archive/runtime-stack/remove.sh"
    assert_not_line '#   sudo ./apply.sh' "${repo_root}/archive/runtime-stack/apply.sh"
    assert_not_contains '`sudo ./apply.sh`' "${repo_root}/archive/runtime-stack/apply.sh"
    assert_not_contains 'sudo ./reset.sh --probe' "${repo_root}/archive/runtime-stack/reset.sh"
    assert_not_contains 'sudo ./reset.sh --recover' "${repo_root}/archive/runtime-stack/reset.sh"
    assert_not_contains 'sudo ./reset.sh --auto' "${repo_root}/archive/runtime-stack/reset.sh"
    assert_not_contains 'sudo ./reset.sh --verbose' "${repo_root}/archive/runtime-stack/reset.sh"
}

main() {
    test_root_package_workspace_exists
    test_repo_patch_manifest_declares_base_then_addon_then_local_order
    test_root_no_longer_owns_upstream_package_files
    test_nested_package_workspace_is_removed
    test_runtime_stack_is_archived
    test_runtime_docs_are_archived_but_superpowers_docs_remain_active
    test_archived_build_paths_point_at_live_patch_series
}

main "$@"
