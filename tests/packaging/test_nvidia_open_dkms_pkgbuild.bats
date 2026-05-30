#!/usr/bin/env bash
# Intentionally executable Bash despite the .bats suffix:
# this host does not have bats, and the plan allows a bash fallback harness.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
pkg_dir="${repo_root}"
wrapper="${repo_root}/build-local-package.sh"
readme="${repo_root}/README.md"
patch_audit="${repo_root}/patch-audit.md"
legacy_patch_layer_token='patches-'"local"
legacy_gate_config_token='nvidia-egpu-gates.'"conf"

assert_contains() {
    local needle="$1"
    local file="$2"

    if ! grep -F -- "$needle" "$file" >/dev/null; then
        printf 'missing expected text in %s: %s\n' "$file" "$needle" >&2
        return 1
    fi
}

assert_not_contains() {
    local needle="$1"
    local file="$2"

    if grep -F -- "$needle" "$file" >/dev/null; then
        printf 'found forbidden text in %s: %s\n' "$file" "$needle" >&2
        return 1
    fi
}

assert_has_exact_line() {
    local needle="$1"
    local file="$2"

    if ! grep -Fx -- "$needle" "$file" >/dev/null; then
        printf 'missing expected line in %s: %s\n' "$file" "$needle" >&2
        return 1
    fi
}

assert_line_order() {
    local first_pattern="$1"
    local second_pattern="$2"
    local file="$3"
    local first_line second_line line

    first_line=""
    while IFS=: read -r line _; do
        first_line="$line"
        break
    done < <(grep -n -F -- "$first_pattern" "$file" || true)

    second_line=""
    while IFS=: read -r line _; do
        second_line="$line"
        break
    done < <(grep -n -F -- "$second_pattern" "$file" || true)

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

test_assert_line_order_reports_missing_patterns_without_aborting_shell() {
    local tmpdir input_file stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    input_file="${tmpdir}/input"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    printf 'alpha\nbeta\n' >"$input_file"

    if ASSERT_LINE_ORDER_DEF="$(declare -f assert_line_order)" \
        bash -c 'set -euo pipefail; eval "$ASSERT_LINE_ORDER_DEF"; if assert_line_order "$1" "$2" "$3" 2>"$4"; then exit 99; fi; printf "after-helper\n"' \
        _ \
        'missing-pattern' \
        'beta' \
        "$input_file" \
        "$stderr_file" >"$stdout_file"; then
        if [[ "$(<"$stdout_file")" != 'after-helper' ]]; then
            printf 'assert_line_order caller should continue after a missing pattern\n' >&2
            return 1
        fi
        assert_contains "could not compare order in ${input_file}: missing-pattern / beta" "$stderr_file"
        return 0
    else
        status=$?
    fi

    printf 'expected assert_line_order missing-pattern handling to return control to the caller, got status %s\n' "$status" >&2
    if [[ -f "$stderr_file" ]]; then
        cat "$stderr_file" >&2
    fi
    return 1
}

stage_fake_upstream_tree() {
    local tmpdir="$1"
    local utils_repo="$2"
    local stage_dir="$3"

    MANJARO_TARGET_VERSION=595.71.05-2 \
        MANJARO_NVIDIA_UTILS_REPO="$utils_repo" \
        bash "$wrapper" --stage-only "$stage_dir"
}

create_fake_upstream_repo_with_open_patch() {
    local repo_dir="$1"

    mkdir -p "$repo_dir"
    git -C "$repo_dir" init -q
    git -C "$repo_dir" config user.name test >/dev/null
    git -C "$repo_dir" config user.email test@example.com >/dev/null
    cat >"$repo_dir/PKGBUILD" <<'EOF'
pkgbase=nvidia-utils
pkgname=('nvidia-utils' 'nvidia-open-dkms')
pkgver=595.71.05
pkgrel=2
_pkg="NVIDIA-Linux-x86_64-${pkgver}"
_pkg_open="NVIDIA-kernel-module-source-${pkgver}"
source=("https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/${_pkg_open}.tar.xz"
        'systemd.patch'
        '0002-Add-IBT-support.patch'
        '0007-extra-open.patch')
sha256sums=('1f558b1e7d4cd2b7901ee01bdea6f8bd439916bd61fa36bbf736fbe8703414cd'
            'systemd-sha'
            '40a520b34d55807e6fae54567f41f582235f1a4b22538795a38253ea9df9791d'
            'extra-sha')
prepare() {
    patch -Np1 -i "${srcdir}/systemd.patch" -d "${srcdir}/${_pkg}"
    patch -Np1 -i "${srcdir}/0002-Add-IBT-support.patch" -d "${srcdir}/${_pkg_open}"
    patch -Np1 -i "${srcdir}/0007-extra-open.patch" -d "${srcdir}/${_pkg_open}"
}
package_nvidia-open-dkms() { :; }
EOF
    printf 'systemd upstream patch\n' >"$repo_dir/systemd.patch"
    printf 'ibt upstream patch\n' >"$repo_dir/0002-Add-IBT-support.patch"
    printf 'extra upstream open patch\n' >"$repo_dir/0007-extra-open.patch"
    git -C "$repo_dir" add PKGBUILD systemd.patch 0002-Add-IBT-support.patch 0007-extra-open.patch
    git -C "$repo_dir" commit -q -m 'seed 595.71.05-2'
}

stage_pkgbuild_for_test() {
    local tmpdir="$1"
    local stage_dir="$2"
    local pkgbuild_copy="$3"

    cp "${stage_dir}/PKGBUILD" "$pkgbuild_copy"
}

prepare_runner='set -euo pipefail
source "$1"
pkgver="$2"
srcdir="$3"
startdir="$4"
cd "$srcdir"
prepare'

package_runner='set -euo pipefail
source "$1"
pkgname="nvidia-open-dkms"
pkgver="$2"
srcdir="$3"
pkgdir="$4"
package'

create_minimal_prepare_tree() {
    local srcdir="$1"
    local pkg_root="${srcdir}/NVIDIA-Linux-x86_64-595.71.05"
    local pkg_open_root="${srcdir}/NVIDIA-kernel-module-source-595.71.05"

    mkdir -p "$pkg_root" "$pkg_open_root/kernel-open"
    touch "$srcdir/systemd.patch" "$srcdir/0002-Add-IBT-support.patch" \
        "$srcdir/0007-extra-open.patch" "$srcdir/NVIDIA-Linux-x86_64-595.71.05.run"
    cat >"$pkg_open_root/kernel-open/Kbuild" <<'EOF'
ccflags-y += filler-01
ccflags-y += filler-02
ccflags-y += filler-03
ccflags-y += filler-04
ccflags-y += filler-05
ccflags-y += filler-06
ccflags-y += filler-07
ccflags-y += filler-08
ccflags-y += filler-09
ccflags-y += filler-10
ccflags-y += filler-11
ccflags-y += filler-12
ccflags-y += filler-13
ccflags-y += filler-14
ccflags-y += filler-15
ccflags-y += filler-16
ccflags-y += filler-17
ccflags-y += filler-18
ccflags-y += filler-19
ccflags-y += filler-20
ccflags-y += filler-21
ccflags-y += filler-22
ccflags-y += filler-23
ccflags-y += filler-24
ccflags-y += filler-25
ccflags-y += filler-26
ccflags-y += filler-27
ccflags-y += filler-28
ccflags-y += filler-29
ccflags-y += filler-30
ccflags-y += filler-31
ccflags-y += filler-32
ccflags-y += filler-33
ccflags-y += filler-34
ccflags-y += filler-35
ccflags-y += filler-36
ccflags-y += filler-37
ccflags-y += filler-38
ccflags-y += filler-39
ccflags-y += filler-40
ccflags-y += filler-41
ccflags-y += filler-42
ccflags-y += filler-43
ccflags-y += filler-44
ccflags-y += filler-45
ccflags-y += filler-46
ccflags-y += filler-47
ccflags-y += filler-48
ccflags-y += filler-49
ccflags-y += filler-50
ccflags-y += filler-51
ccflags-y += filler-52
ccflags-y += filler-53
ccflags-y += filler-54
ccflags-y += filler-55
ccflags-y += filler-56
ccflags-y += filler-57
ccflags-y += filler-58
ccflags-y += filler-59
ccflags-y += filler-60
ccflags-y += filler-61
ccflags-y += filler-62
ccflags-y += filler-63
ccflags-y += filler-64
ccflags-y += filler-65
ccflags-y += filler-66
ccflags-y += filler-67
ccflags-y += filler-68
ccflags-y += filler-69
ccflags-y += filler-70
ccflags-y += filler-71
ccflags-y += filler-72
ccflags-y += filler-73
ccflags-y += filler-74
ccflags-y += filler-75
ccflags-y += filler-76
ccflags-y += -I$(src)/common/inc
ccflags-y += -I$(src)
ccflags-y += -Wall $(DEFINES) $(INCLUDES) -Wno-cast-qual -Wno-format-extra-args
ccflags-y += -D__KERNEL__ -DMODULE -DNVRM
ccflags-y += -DNV_VERSION_STRING=\"595.71.05\"

# Include and link Tegra out-of-tree modules.
ifneq ($(wildcard /usr/src/nvidia/nvidia-public),)
  SYSSRCNVOOT ?= /usr/src/nvidia/nvidia-public
endif
EOF
    cat >"$pkg_open_root/version.mk" <<'EOF'
NVIDIA_VERSION = 595.71.05
NVIDIA_NVID_VERSION = 595.71.05
NVIDIA_NVID_EXTRA =

EOF
    touch "$pkg_root/nvidia-persistenced-init.tar.bz2" "$pkg_root/nvidia-settings.desktop"
    cat >"$pkg_open_root/utils.mk" <<'EOF'
  HOSTNAME = builder
WHOAMI = builder
DATE = now
EOF
    cat >"$pkg_open_root/kernel-open/dkms.conf" <<'EOF'
PACKAGE_VERSION="__VERSION_STRING"
MAKE[0]="'make' -j__JOBS NV_EXCLUDE_BUILD_MODULES"
__EXCLUDE_MODULES
__DKMS_MODULES
EOF
}

create_minimal_open_dkms_package_tree() {
    local srcdir="$1"
    local tree_dir="${srcdir}/NVIDIA-kernel-module-source-595.71.05"

    mkdir -p "${tree_dir}/kernel-open"
    cat >"${tree_dir}/kernel-open/dkms.conf" <<'EOF'
PACKAGE_VERSION="595.71.05"
MAKE[0]="'make' -j8 IGNORE_PREEMPT_RT_PRESENCE=1 NV_EXCLUDE_BUILD_MODULES"
EOF
    cat >"${tree_dir}/version.mk" <<'EOF'
NVIDIA_VERSION = 595.71.05
EOF
    touch "${tree_dir}/COPYING"
}

run_pkgbuild_prepare() {
    local pkgbuild_copy="$1"
    local srcdir="$2"
    local startdir="$3"

    bash -c "$prepare_runner" -- \
        "$pkgbuild_copy" \
        "595.71.05" \
        "$srcdir" \
        "$startdir"
}

run_pkgbuild_package() {
    local pkgbuild_copy="$1"
    local srcdir="$2"
    local pkgdir="$3"

    bash -c "$package_runner" -- \
        "$pkgbuild_copy" \
        "595.71.05" \
        "$srcdir" \
        "$pkgdir"
}

test_staged_pkgbuild_prepare_applies_upstream_then_base_then_addon_then_local_patches() {
    local tmpdir utils_repo stage_dir pkgbuild_copy stub_dir log_file srcdir startdir
    tmpdir="$(mktemp -d)"
    stage_dir="${tmpdir}/stage"
    startdir="${stage_dir}"
    srcdir="${tmpdir}/src"
    pkgbuild_copy="${tmpdir}/PKGBUILD"
    stub_dir="${tmpdir}/bin"
    log_file="${tmpdir}/patch.log"
    utils_repo="${tmpdir}/nvidia-utils"

    trap "rm -rf -- '$tmpdir'" RETURN

    mkdir -p "$stub_dir"
    create_fake_upstream_repo_with_open_patch "$utils_repo"
    stage_fake_upstream_tree "$tmpdir" "$utils_repo" "$stage_dir"
    stage_pkgbuild_for_test "$tmpdir" "$stage_dir" "$pkgbuild_copy"
    : >"$log_file"
    create_minimal_prepare_tree "$srcdir"

    cat >"${stub_dir}/patch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
patch_file=""
target_dir=""
while (($#)); do
    if [[ "$1" == "-i" ]]; then
        patch_file="$2"
        shift 2
        continue
    fi
    if [[ "$1" == "-d" ]]; then
        target_dir="$2"
        shift 2
        continue
    fi
    shift
done
    printf 'target=%s patch=%s\n' "$target_dir" "${patch_file##*/}" >>"$LOG_FILE"
EOF
    chmod +x "${stub_dir}/patch"
    for command_name in sh bsdtar desktop-file-edit; do
        cat >"${stub_dir}/${command_name}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
        chmod +x "${stub_dir}/${command_name}"
    done

    LOG_FILE="$log_file" PATH="${stub_dir}:${PATH}" \
        run_pkgbuild_prepare "$pkgbuild_copy" "$srcdir" "$startdir"

    assert_contains "target=${srcdir}/NVIDIA-kernel-module-source-595.71.05 patch=0002-Add-IBT-support.patch" "$log_file"
    assert_contains "target=${srcdir}/NVIDIA-kernel-module-source-595.71.05 patch=0007-extra-open.patch" "$log_file"
    assert_contains "target=${srcdir}/NVIDIA-kernel-module-source-595.71.05 patch=C1-kbuild-version-mk.patch" "$log_file"
    assert_contains "target=${srcdir}/NVIDIA-kernel-module-source-595.71.05 patch=C5-crash-safety.patch" "$log_file"
    assert_contains "target=${srcdir}/NVIDIA-kernel-module-source-595.71.05 patch=A1-pcie-primitives.patch" "$log_file"
    assert_contains "target=${srcdir}/NVIDIA-kernel-module-source-595.71.05 patch=A5-version-and-toggles.patch" "$log_file"
    assert_contains "target=${srcdir}/NVIDIA-kernel-module-source-595.71.05 patch=L1-no-suffix-version-string.patch" "$log_file"
    assert_not_contains 'patch=systemd.patch' "$log_file"
    assert_line_order 'patch=0002-Add-IBT-support.patch' 'patch=0007-extra-open.patch' "$log_file"
    assert_line_order 'patch=0007-extra-open.patch' 'patch=C1-kbuild-version-mk.patch' "$log_file"
    assert_line_order 'patch=C1-kbuild-version-mk.patch' 'patch=C5-crash-safety.patch' "$log_file"
    assert_line_order 'patch=C5-crash-safety.patch' 'patch=A1-pcie-primitives.patch' "$log_file"
    assert_line_order 'patch=A1-pcie-primitives.patch' 'patch=A5-version-and-toggles.patch' "$log_file"
    assert_line_order 'patch=A5-version-and-toggles.patch' 'patch=L1-no-suffix-version-string.patch' "$log_file"
}

test_prepare_semantically_restores_upstream_version_mk_after_a5_then_l1() {
    local tmpdir utils_repo repo_copy stage_dir pkgbuild_copy srcdir startdir version_mk
    tmpdir="$(mktemp -d)"
    repo_copy="${tmpdir}/repo-copy"
    stage_dir="${tmpdir}/stage"
    startdir="${stage_dir}"
    srcdir="${tmpdir}/src"
    pkgbuild_copy="${tmpdir}/PKGBUILD"
    version_mk="${srcdir}/NVIDIA-kernel-module-source-595.71.05/version.mk"
    utils_repo="${tmpdir}/nvidia-utils"

    trap "rm -rf -- '$tmpdir'" RETURN

    create_fake_upstream_repo_with_open_patch "$utils_repo"
    mkdir -p "$repo_copy"
    cp -a "${repo_root}/build-local-package.sh" "${repo_root}/patches" "$repo_copy/"
    cat >"${repo_copy}/patches/manifest" <<'EOF'
# Patch manifest -- the declared contract for the injector's patch set.
# Columns:  id  layer  upstreamed_in  source
#   id             logical patch id; file is patches/<layer>/<id>.patch
#   layer          base (de-branded, upstream-bound) | addon (project-local, vendored from the injector stack) | local (repo-owned final override layer)
#   upstreamed_in  '-' = still needed; else the NVIDIA tag that absorbed it
#   source         fork:<branch> for vendored injector rows; repo:<name> for repo-local override rows
# Row order = apply order.
#
# id                        layer  upstreamed_in  source
  C1-kbuild-version-mk       base   -              fork:c1-kbuild-version-mk
  A5-version-and-toggles     addon  -              fork:a5-version-and-toggles
  L1-no-suffix-version-string local -              repo:l1-no-suffix-version-string
EOF

    MANJARO_TARGET_VERSION=595.71.05-2 \
        MANJARO_NVIDIA_UTILS_REPO="$utils_repo" \
        bash "${repo_copy}/build-local-package.sh" --stage-only "$stage_dir"
    stage_pkgbuild_for_test "$tmpdir" "$stage_dir" "$pkgbuild_copy"
    create_minimal_prepare_tree "$srcdir"

    run_pkgbuild_prepare "$pkgbuild_copy" "$srcdir" "$startdir"

    assert_contains 'NVIDIA_VERSION = 595.71.05' "$version_mk"
    assert_not_contains '595.71.05-aorus.14' "$version_mk"
}

test_package_generates_expanded_dkms_conf() {
    local tmpdir utils_repo stage_dir pkgbuild_copy startdir srcdir pkgdir output_dkms_conf stub_dir
    tmpdir="$(mktemp -d)"
    stage_dir="${tmpdir}/stage"
    pkgbuild_copy="${tmpdir}/PKGBUILD"
    startdir="${stage_dir}"
    srcdir="${tmpdir}/src"
    pkgdir="${tmpdir}/pkg"
    output_dkms_conf="${pkgdir}/usr/src/nvidia-595.71.05/dkms.conf"
    stub_dir="${tmpdir}/bin"
    utils_repo="${tmpdir}/nvidia-utils"

    trap "rm -rf -- '$tmpdir'" RETURN

    mkdir -p "$pkgdir" "$stub_dir"
    create_fake_upstream_repo_with_open_patch "$utils_repo"
    stage_fake_upstream_tree "$tmpdir" "$utils_repo" "$stage_dir"
    stage_pkgbuild_for_test "$tmpdir" "$stage_dir" "$pkgbuild_copy"
    create_minimal_prepare_tree "$srcdir"
    touch "${srcdir}/NVIDIA-kernel-module-source-595.71.05/COPYING"

    for command_name in patch sh bsdtar desktop-file-edit; do
        cat >"${stub_dir}/${command_name}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
        chmod +x "${stub_dir}/${command_name}"
    done

    PATH="${stub_dir}:${PATH}" run_pkgbuild_prepare "$pkgbuild_copy" "$srcdir" "$startdir"
    run_pkgbuild_package "$pkgbuild_copy" "$srcdir" "$pkgdir"

    assert_contains 'PACKAGE_VERSION="595.71.05"' "$output_dkms_conf"
    assert_contains "IGNORE_PREEMPT_RT_PRESENCE=1" "$output_dkms_conf"
    assert_has_exact_line 'BUILT_MODULE_NAME[0]="nvidia"' "$output_dkms_conf"
    assert_has_exact_line 'BUILT_MODULE_LOCATION[0]="kernel-open"' "$output_dkms_conf"
    assert_has_exact_line 'DEST_MODULE_LOCATION[0]="/kernel/drivers/video"' "$output_dkms_conf"
    assert_has_exact_line 'BUILT_MODULE_NAME[1]="nvidia-uvm"' "$output_dkms_conf"
    assert_has_exact_line 'BUILT_MODULE_NAME[2]="nvidia-modeset"' "$output_dkms_conf"
    assert_has_exact_line 'BUILT_MODULE_NAME[3]="nvidia-drm"' "$output_dkms_conf"
    assert_has_exact_line 'BUILT_MODULE_NAME[4]="nvidia-peermem"' "$output_dkms_conf"
    assert_not_contains '__DKMS_MODULES' "$output_dkms_conf"
    assert_not_contains '__VERSION_STRING' "$output_dkms_conf"
    assert_not_contains '__JOBS' "$output_dkms_conf"
    assert_not_contains '__EXCLUDE_MODULES' "$output_dkms_conf"
}

test_pkgbuild_has_no_firmware_compat_symlink_logic() {
    local tmpdir utils_repo stage_dir pkgbuild_copy srcdir pkgdir tree_dir firmware_dir artifact
    tmpdir="$(mktemp -d)"
    stage_dir="${tmpdir}/stage"
    pkgbuild_copy="${tmpdir}/PKGBUILD"
    srcdir="${tmpdir}/src"
    pkgdir="${tmpdir}/pkg"
    tree_dir="${srcdir}/NVIDIA-kernel-module-source-595.71.05"
    firmware_dir="${pkgdir}/usr/lib/firmware/nvidia"
    utils_repo="${tmpdir}/nvidia-utils"

    trap "rm -rf -- '$tmpdir'" RETURN

    mkdir -p "$tree_dir/kernel-open" "$pkgdir"
    create_fake_upstream_repo_with_open_patch "$utils_repo"
    stage_fake_upstream_tree "$tmpdir" "$utils_repo" "$stage_dir"
    stage_pkgbuild_for_test "$tmpdir" "$stage_dir" "$pkgbuild_copy"
    create_minimal_open_dkms_package_tree "$srcdir"

    run_pkgbuild_package "$pkgbuild_copy" "$srcdir" "$pkgdir"

    for artifact in $(compgen -G "${firmware_dir}/595.71.05-*"); do
        printf 'unexpected firmware compatibility artifact: %s\n' "$artifact" >&2
        return 1
    done

    assert_not_contains 'patched_version=' "$pkgbuild_copy"
    assert_not_contains 'firmware_compat_dir=' "$pkgbuild_copy"
    assert_not_contains 'ln -sfn "${pkgver}"' "$pkgbuild_copy"
}

test_staged_pkgbuild_is_dedicated_to_nvidia_open_dkms() {
    local tmpdir utils_repo stage_dir
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"

    create_fake_upstream_repo_with_open_patch "$utils_repo"
    stage_fake_upstream_tree "$tmpdir" "$utils_repo" "$stage_dir"

    assert_contains 'pkgname=nvidia-open-dkms' "${stage_dir}/PKGBUILD"
    assert_not_contains 'pkgbase=nvidia-utils' "${stage_dir}/PKGBUILD"
    assert_not_contains 'package_nvidia-utils()' "${stage_dir}/PKGBUILD"
    assert_not_contains 'package_opencl-nvidia()' "${stage_dir}/PKGBUILD"
    assert_not_contains 'package_nvidia-settings()' "${stage_dir}/PKGBUILD"
}

test_pkgbuild_installs_dkms_source_into_usr_src() {
    local tmpdir utils_repo stage_dir
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"

    create_fake_upstream_repo_with_open_patch "$utils_repo"
    stage_fake_upstream_tree "$tmpdir" "$utils_repo" "$stage_dir"

    assert_contains "cp -dr --no-preserve='ownership'" "${stage_dir}/PKGBUILD"
    assert_contains '"${pkgdir}/usr/src/nvidia-595.71.05"' "${stage_dir}/PKGBUILD"
}

test_pkgbuild_uses_manifest_derived_patch_series() {
    local tmpdir utils_repo stage_dir
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"

    create_fake_upstream_repo_with_open_patch "$utils_repo"
    stage_fake_upstream_tree "$tmpdir" "$utils_repo" "$stage_dir"

    assert_contains 'repo_patches_dir="${repo_root}/patches"' "${stage_dir}/PKGBUILD"
    assert_contains 'base_patch_series=(' "${stage_dir}/PKGBUILD"
    assert_contains 'addon_patch_series=(' "${stage_dir}/PKGBUILD"
    assert_contains 'local_patch_series=(' "${stage_dir}/PKGBUILD"
    assert_contains 'base/C1-kbuild-version-mk.patch' "${stage_dir}/PKGBUILD"
    assert_contains 'base/C5-crash-safety.patch' "${stage_dir}/PKGBUILD"
    assert_contains 'addon/A1-pcie-primitives.patch' "${stage_dir}/PKGBUILD"
    assert_contains 'addon/A5-version-and-toggles.patch' "${stage_dir}/PKGBUILD"
    assert_contains 'local/L1-no-suffix-version-string.patch' "${stage_dir}/PKGBUILD"
    assert_line_order 'base/C1-kbuild-version-mk.patch' 'base/C5-crash-safety.patch' "${stage_dir}/PKGBUILD"
    assert_line_order 'addon/A1-pcie-primitives.patch' 'addon/A5-version-and-toggles.patch' "${stage_dir}/PKGBUILD"
    assert_line_order 'base/C5-crash-safety.patch' 'addon/A1-pcie-primitives.patch' "${stage_dir}/PKGBUILD"
    assert_line_order 'addon/A5-version-and-toggles.patch' 'local/L1-no-suffix-version-string.patch' "${stage_dir}/PKGBUILD"
    assert_not_contains 'repo_patch_series=("${repo_patches_dir}"/*.patch)' "${stage_dir}/PKGBUILD"
}

test_pkgbuild_applies_upstream_then_base_then_addon_then_local_series() {
    local tmpdir utils_repo stage_dir
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"

    create_fake_upstream_repo_with_open_patch "$utils_repo"
    stage_fake_upstream_tree "$tmpdir" "$utils_repo" "$stage_dir"

    assert_line_order 'for patch in "${upstream_patch_series[@]}"; do' \
        'for patch in "${base_patch_series[@]}"; do' \
        "${stage_dir}/PKGBUILD"
    assert_line_order 'for patch in "${base_patch_series[@]}"; do' \
        'for patch in "${addon_patch_series[@]}"; do' \
        "${stage_dir}/PKGBUILD"
    assert_line_order 'for patch in "${addon_patch_series[@]}"; do' \
        'for patch in "${local_patch_series[@]}"; do' \
        "${stage_dir}/PKGBUILD"
    assert_line_order 'base/C5-crash-safety.patch' 'addon/A1-pcie-primitives.patch' "${stage_dir}/PKGBUILD"
    assert_line_order 'addon/A1-pcie-primitives.patch' 'addon/A5-version-and-toggles.patch' "${stage_dir}/PKGBUILD"
    assert_line_order 'addon/A5-version-and-toggles.patch' 'local/L1-no-suffix-version-string.patch' "${stage_dir}/PKGBUILD"
}

test_pkgbuild_uses_real_sha256_checksums() {
    local tmpdir utils_repo stage_dir
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"

    create_fake_upstream_repo_with_open_patch "$utils_repo"
    stage_fake_upstream_tree "$tmpdir" "$utils_repo" "$stage_dir"

    assert_contains "sha256sums=(" "${stage_dir}/PKGBUILD"
    assert_not_contains "'SKIP'" "${stage_dir}/PKGBUILD"
    assert_not_contains '"SKIP"' "${stage_dir}/PKGBUILD"
}

test_build_wrapper_uses_staged_dedicated_pkgbuild_without_pkg_flag() {
    local tmpdir stub_dir record_file cwd_file staged_pkgbuild_file stdout_file utils_repo
    tmpdir="$(mktemp -d)"
    stub_dir="${tmpdir}/bin"
    record_file="${tmpdir}/args"
    cwd_file="${tmpdir}/cwd"
    staged_pkgbuild_file="${tmpdir}/staged.PKGBUILD"
    stdout_file="${tmpdir}/stdout"
    utils_repo="${tmpdir}/nvidia-utils"
    mkdir -p "$stub_dir"

    trap "rm -rf -- '$tmpdir'" RETURN

    create_fake_upstream_repo_with_open_patch "$utils_repo"

cat >"${stub_dir}/makepkg" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$PWD" >"${cwd_file}"
cp "\$PWD/PKGBUILD" "${staged_pkgbuild_file}"
printf '%s\n' "\$@" >"${record_file}"
printf '%s\n' "\$PWD/nvidia-open-dkms-595.71.05-2-x86_64.pkg.tar.zst"
EOF
    chmod +x "${stub_dir}/makepkg"

    PATH="${stub_dir}:${PATH}" \
        MANJARO_TARGET_VERSION=595.71.05-2 \
        MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
        bash "$wrapper" --packagelist >"${stdout_file}"

    if [[ "$(<"${cwd_file}")" == "$pkg_dir" ]]; then
        printf 'build wrapper unexpectedly invoked makepkg from repo root\n' >&2
        return 1
    fi

    assert_contains 'pkgname=nvidia-open-dkms' "$staged_pkgbuild_file"
    assert_not_contains 'pkgbase=nvidia-utils' "$staged_pkgbuild_file"
    assert_not_contains '--pkg' "$record_file"
    assert_contains '--packagelist' "$record_file"
    assert_contains 'nvidia-open-dkms-595.71.05-2-x86_64.pkg.tar.zst' "$stdout_file"
}

test_build_wrapper_is_executable() {
    if [[ ! -x "$wrapper" ]]; then
        printf 'build wrapper is not executable: %s\n' "$wrapper" >&2
        return 1
    fi
}

test_staged_pkgbuild_does_not_reference_nvidia_run_payload() {
    local tmpdir utils_repo stage_dir
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"

    create_fake_upstream_repo_with_open_patch "$utils_repo"
    stage_fake_upstream_tree "$tmpdir" "$utils_repo" "$stage_dir"

    assert_not_contains 'NVIDIA-Linux-x86_64-${pkgver}.run' "${stage_dir}/PKGBUILD"
    assert_not_contains 'nvidia-persistenced-init.tar.bz2' "${stage_dir}/PKGBUILD"
    assert_not_contains 'desktop-file-edit' "${stage_dir}/PKGBUILD"
}

test_readme_documents_dynamic_patch_pipeline() {
    assert_contains 'preserves every upstream patch that the fetched Manjaro `prepare()` flow applies to `${_pkg_open}`' "$readme"
    assert_contains 'then applies this repo'"'"'s vendored injector `patches/base` phase,' "$readme"
    assert_contains 'followed by this repo'"'"'s vendored injector `patches/addon` phase,' "$readme"
    assert_contains 'and finally this repo'"'"'s `patches/local` override phase.' "$readme"
    assert_not_contains "$legacy_patch_layer_token" "$readme"
    assert_not_contains "$legacy_gate_config_token" "$readme"
}

test_patch_audit_documents_local_override_phase() {
    assert_contains 'apply order across all three downstream phases.' "$patch_audit"
    assert_contains '## Local Phase' "$patch_audit"
    assert_contains '| `L1-no-suffix-version-string.patch` | runtime version compatibility | Final repo-local override that resets `NVIDIA_VERSION` to upstream `595.71.05` after vendored addon `A5`, keeping firmware lookup and module cross-checks aligned with stock `nvidia-utils`. |' "$patch_audit"
}

main() {
    test_assert_line_order_reports_missing_patterns_without_aborting_shell
    test_staged_pkgbuild_is_dedicated_to_nvidia_open_dkms
    test_staged_pkgbuild_does_not_reference_nvidia_run_payload
    test_pkgbuild_installs_dkms_source_into_usr_src
    test_pkgbuild_uses_manifest_derived_patch_series
    test_pkgbuild_applies_upstream_then_base_then_addon_then_local_series
    test_staged_pkgbuild_prepare_applies_upstream_then_base_then_addon_then_local_patches
    test_prepare_semantically_restores_upstream_version_mk_after_a5_then_l1
    test_package_generates_expanded_dkms_conf
    test_pkgbuild_has_no_firmware_compat_symlink_logic
    test_pkgbuild_uses_real_sha256_checksums
    test_build_wrapper_uses_staged_dedicated_pkgbuild_without_pkg_flag
    test_build_wrapper_is_executable
    test_readme_documents_dynamic_patch_pipeline
    test_patch_audit_documents_local_override_phase
}

main "$@"
