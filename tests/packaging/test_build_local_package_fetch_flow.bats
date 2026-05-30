#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
wrapper="${repo_root}/build-local-package.sh"
legacy_patch_layer_dir_name='patches-'"local"

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$expected" == "$actual" ]] || {
        printf '%s: expected %s, got %s\n' "$message" "$expected" "$actual" >&2
        return 1
    }
}

assert_contains() {
    local needle="$1"
    local file="$2"
    grep -F -- "$needle" "$file" >/dev/null || {
        printf 'missing expected text in %s: %s\n' "$file" "$needle" >&2
        return 1
    }
}

assert_not_contains() {
    local needle="$1"
    local file="$2"
    if grep -F -- "$needle" "$file" >/dev/null; then
        printf 'found forbidden text in %s: %s\n' "$file" "$needle" >&2
        return 1
    fi
}

assert_matches() {
    local pattern="$1"
    local file="$2"
    rg -n --pcre2 -- "$pattern" "$file" >/dev/null || {
        printf 'missing expected pattern in %s: %s\n' "$file" "$pattern" >&2
        return 1
    }
}

assert_not_matches() {
    local pattern="$1"
    local file="$2"
    if rg -n --pcre2 -- "$pattern" "$file" >/dev/null; then
        printf 'found forbidden pattern in %s: %s\n' "$file" "$pattern" >&2
        return 1
    fi
}

dedicated_pkgbuild_pkgname_pattern() {
    printf '%s\n' '^pkgname=(?:nvidia-open-dkms|'\''nvidia-open-dkms'\''|"nvidia-open-dkms"|\(\s*(?:nvidia-open-dkms|'\''nvidia-open-dkms'\''|"nvidia-open-dkms")\s*\))$'
}

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

assert_no_leaked_mktemp_dirs() {
    local parent_dir="$1"
    local path

    shopt -s nullglob
    for path in "$parent_dir"/tmp.*; do
        printf 'expected no leaked temporary directories, found: %s\n' "$path" >&2
        shopt -u nullglob
        return 1
    done
    shopt -u nullglob
}

run_wrapper_capture() {
    local stdout_file="$1"
    local stderr_file="$2"
    local status
    shift 2

    if "$@" >"$stdout_file" 2>"$stderr_file"; then
        return 0
    else
        status=$?
    fi

    return "$status"
}

create_fake_repo() {
    local repo_dir="$1"
    local pkgver="$2"
    local pkgrel="$3"
    mkdir -p "$repo_dir"
    git -C "$repo_dir" init -q
    git -C "$repo_dir" config user.name test >/dev/null
    git -C "$repo_dir" config user.email test@example.com >/dev/null
    cat >"$repo_dir/PKGBUILD" <<EOF
pkgbase=nvidia-utils
pkgname=('nvidia-utils' 'nvidia-open-dkms')
pkgver=${pkgver}
pkgrel=${pkgrel}
_pkg_open="NVIDIA-kernel-module-source-${pkgver}"
source=("https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/\${_pkg_open}.tar.xz"
        '0002-Add-IBT-support.patch')
sha256sums=('tarball-sha'
            'ibt-sha')
prepare() { :; }
package_nvidia-open-dkms() { :; }
EOF
    printf 'upstream-only fixture\n' >"$repo_dir/upstream-only.marker"
    printf 'upstream ibt fixture\n' >"$repo_dir/0002-Add-IBT-support.patch"
    git -C "$repo_dir" add PKGBUILD upstream-only.marker 0002-Add-IBT-support.patch
    git -C "$repo_dir" commit -q -m "seed ${pkgver}-${pkgrel}"
}

create_fake_repo_with_open_patch_series() {
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
        "0007-extra-open.patch::https://example.invalid/extra-open.patch")
sha256sums=('tarball-sha'
            'systemd-sha'
            'ibt-sha'
            'extra-sha')
prepare() {
    patch -Np1 -i "${srcdir}/systemd.patch" -d "${srcdir}/${_pkg}"
    patch -Np1 -i "${srcdir}/0002-Add-IBT-support.patch" -d "${srcdir}/${_pkg_open}"
    patch -Np1 -i "${srcdir}/0007-extra-open.patch" -d "${srcdir}/${_pkg_open}"
}
package_nvidia-open-dkms() { :; }
EOF
    printf 'upstream-only fixture\n' >"$repo_dir/upstream-only.marker"
    printf 'upstream systemd fixture\n' >"$repo_dir/systemd.patch"
    printf 'upstream ibt fixture\n' >"$repo_dir/0002-Add-IBT-support.patch"
    printf 'upstream extra open fixture\n' >"$repo_dir/0007-extra-open.patch"
    git -C "$repo_dir" add PKGBUILD upstream-only.marker systemd.patch \
        0002-Add-IBT-support.patch 0007-extra-open.patch
    git -C "$repo_dir" commit -q -m 'seed upstream open patch series'
}

create_fake_repo_with_pkgbuild_fixture() {
    local repo_dir="$1"
    local commit_message="$2"
    local pkgbuild_content="$3"
    shift 3

    mkdir -p "$repo_dir"
    git -C "$repo_dir" init -q
    git -C "$repo_dir" config user.name test >/dev/null
    git -C "$repo_dir" config user.email test@example.com >/dev/null
    printf '%s\n' "$pkgbuild_content" >"$repo_dir/PKGBUILD"
    git -C "$repo_dir" add PKGBUILD

    while (( $# > 0 )); do
        printf '%s\n' "$2" >"$repo_dir/$1"
        git -C "$repo_dir" add "$1"
        shift 2
    done

    git -C "$repo_dir" commit -q -m "$commit_message"
}

copy_wrapper_repo_fixture() {
    local dest="$1"
    local entry

    mkdir -p "$dest"

    shopt -s dotglob nullglob
    for entry in "${repo_root}"/*; do
        [[ "${entry##*/}" == '.git' ]] && continue
        cp -a "$entry" "$dest/"
    done
    shopt -u dotglob nullglob
}

run_wrapper_from_repo_copy() {
    local repo_copy="$1"
    shift

    bash "${repo_copy}/build-local-package.sh" "$@"
}

write_fake_pkgbuild() {
    local repo_dir="$1"
    local pkgver="$2"
    local pkgrel="$3"
    local extra_body="${4-}"

    {
        printf 'pkgbase=nvidia-utils\n'
        printf "pkgname=('nvidia-utils' 'nvidia-open-dkms')\n"
        printf 'pkgver=%s\n' "$pkgver"
        printf 'pkgrel=%s\n' "$pkgrel"
        printf '_pkg_open="NVIDIA-kernel-module-source-${pkgver}"\n'
        printf 'source=("https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/${_pkg_open}.tar.xz"\n'
        printf "        '0002-Add-IBT-support.patch')\n"
        printf "sha256sums=('tarball-sha'\n"
        printf "            'ibt-sha')\n"
        if [[ -n "$extra_body" ]]; then
            printf '%s\n' "$extra_body"
        fi
        printf 'prepare() { :; }\n'
        printf 'package_nvidia-open-dkms() { :; }\n'
    } >"$repo_dir/PKGBUILD"
}

commit_fake_repo_version() {
    local repo_dir="$1"
    local pkgver="$2"
    local pkgrel="$3"
    local extra_body="${4-}"

    write_fake_pkgbuild "$repo_dir" "$pkgver" "$pkgrel" "$extra_body"
    git -C "$repo_dir" add PKGBUILD
    git -C "$repo_dir" commit -q -m "seed ${pkgver}-${pkgrel}"
}

update_fake_repo_version() {
    local repo_dir="$1"
    local pkgver="$2"
    local pkgrel="$3"

    commit_fake_repo_version "$repo_dir" "$pkgver" "$pkgrel"
}

create_fake_makepkg() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/makepkg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == "--help" ]]; then
    printf '%s\n' '  --pkg <name>'
    exit 0
fi
printf 'fake makepkg failure\n' >&2
exit 1
EOF
    chmod 755 "$bin_dir/makepkg"
}

create_fake_makepkg_without_pkg_support() {
    local bin_dir="$1"
    local record_file="$2"
    local artifact_name="$3"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/makepkg" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1-}" == "--help" ]]; then
    cat <<'HELP'
Usage: makepkg [options]
  --packagelist
HELP
    exit 0
fi
printf '%s\n' "\$@" >"${record_file}"
if printf '%s\0' "\$@" | grep -Fzx -- '--pkg' >/dev/null; then
    printf 'fake makepkg received unsupported --pkg flag\n' >&2
    exit 99
fi
touch "\$PWD/${artifact_name}"
EOF
    chmod 755 "$bin_dir/makepkg"
}

create_fake_makepkg_query_only() {
    local bin_dir="$1"
    local record_file="$2"
    local artifact_name="$3"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/makepkg" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1-}" == "--help" ]]; then
    printf '%s\n' '  --pkg <name>'
    exit 0
fi
printf '%s\n' "\$@" >"${record_file}"
printf '%s\n' "\$PWD/${artifact_name}"
EOF
    chmod 755 "$bin_dir/makepkg"
}

create_fake_makepkg_source_mode() {
    local bin_dir="$1"
    local record_file="$2"
    local artifact_name="$3"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/makepkg" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1-}" == "--help" ]]; then
    printf '%s\n' '  --pkg <name>'
    exit 0
fi
printf '%s\n' "\$@" >"${record_file}"
touch "\$PWD/${artifact_name}"
EOF
    chmod 755 "$bin_dir/makepkg"
}

create_fake_makepkg_records_repo_root() {
    local bin_dir="$1"
    local repo_root_file="$2"
    local cwd_file="$3"
    local artifact_name="$4"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/makepkg" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1-}" == "--help" ]]; then
    printf '%s\n' '  --pkg <name>'
    exit 0
fi
printf '%s\n' "\${AORUS_REPO_ROOT-}" >"${repo_root_file}"
printf '%s\n' "\$PWD" >"${cwd_file}"
touch "\$PWD/${artifact_name}"
EOF
    chmod 755 "$bin_dir/makepkg"
}

create_fake_pacman() {
    local bin_dir="$1"
    local package_version="$2"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/pacman" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1-}" == "-Q" && "\${2-}" == "nvidia-open-dkms" ]]; then
    printf 'nvidia-open-dkms %s\n' '${package_version}'
    exit 0
fi
exit 1
EOF
    chmod 755 "$bin_dir/pacman"
}

create_fake_pacman_with_installed_versions() {
    local bin_dir="$1"
    local open_dkms_version="$2"
    local utils_version="$3"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/pacman" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1-}" != "-Q" ]]; then
    exit 1
fi
case "\${2-}" in
    nvidia-open-dkms)
        printf 'nvidia-open-dkms %s\n' '${open_dkms_version}'
        exit 0
        ;;
    nvidia-utils)
        printf 'nvidia-utils %s\n' '${utils_version}'
        exit 0
        ;;
esac
exit 1
EOF
    chmod 755 "$bin_dir/pacman"
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
        assert_equals 'after-helper' "$(<"$stdout_file")" "assert_line_order caller should continue after a missing pattern"
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

test_copy_wrapper_repo_fixture_excludes_git_without_rsync_dependency() {
    local tmpdir repo_copy fake_bin
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    repo_copy="${tmpdir}/repo-copy"
    fake_bin="${tmpdir}/bin"

    mkdir -p "$fake_bin"
    cat >"${fake_bin}/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'unexpected rsync invocation\n' >&2
exit 127
EOF
    chmod 755 "${fake_bin}/rsync"

    PATH="${fake_bin}:${PATH}" copy_wrapper_repo_fixture "$repo_copy"

    assert_exists "${repo_copy}/build-local-package.sh"
    assert_not_exists "${repo_copy}/.git"
}

test_print_source_repo_prefers_nvidia_utils() {
    local tmpdir utils_repo archived_repo output stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    archived_repo="${tmpdir}/nvidia-open-dkms"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    create_fake_repo "$utils_repo" 595.71.05 2
    update_fake_repo_version "$utils_repo" 600.10.01 1
    create_fake_repo "$archived_repo" 595.71.05 2

    if MANJARO_TARGET_VERSION=595.71.05-2 \
        MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
        MANJARO_NVIDIA_OPEN_DKMS_REPO="${archived_repo}" \
        run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --print-source-repo; then
        output="$(<"$stdout_file")"
        assert_equals "nvidia-utils" "$output" "live repo should win when both match"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_print_source_repo_requires_nvidia_utils_match() {
    local tmpdir utils_repo archived_repo stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    archived_repo="${tmpdir}/nvidia-open-dkms"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    create_fake_repo "$utils_repo" 590.48.01 5
    create_fake_repo "$archived_repo" 595.71.05 2
    update_fake_repo_version "$archived_repo" 600.10.01 1

    if MANJARO_TARGET_VERSION=595.71.05-2 \
        MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
        MANJARO_NVIDIA_OPEN_DKMS_REPO="${archived_repo}" \
        run_wrapper_capture "$stdout_file" "$stderr_file" \
        bash "$wrapper" --print-source-repo; then
        printf 'expected wrapper to reject archived-only match\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail when nvidia-utils has no matching version"
    assert_contains 'no upstream Manjaro nvidia-utils package repo contains target version 595.71.05-2' "$stderr_file"
}

test_print_source_repo_surfaces_checkout_failures() {
    local tmpdir missing_repo stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    missing_repo="${tmpdir}/missing-repo"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    if TMPDIR="$tmpdir" \
        MANJARO_TARGET_VERSION=595.71.05-2 \
        MANJARO_NVIDIA_UTILS_REPO="${missing_repo}" \
        run_wrapper_capture "$stdout_file" "$stderr_file" \
        bash "$wrapper" --print-source-repo; then
        printf 'expected wrapper to fail when upstream checkout cannot be cloned\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail when upstream checkout clone fails"
    assert_contains 'fatal:' "$stderr_file"
    assert_contains "failed to clone upstream Manjaro nvidia-utils repo from ${missing_repo}" "$stderr_file"
    assert_not_contains 'fatal: cannot change to' "$stderr_file"
    assert_not_contains 'no upstream Manjaro nvidia-utils package repo contains target version 595.71.05-2' "$stderr_file"
    assert_no_leaked_mktemp_dirs "$tmpdir"
}

test_stage_only_stages_manifest_base_addon_and_local_patch_tree() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    create_fake_repo_with_open_patch_series "$utils_repo"

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_exists "${stage_dir}/upstream-only.marker"
        assert_exists "${stage_dir}/patches/manifest"
        assert_exists "${stage_dir}/patches/base/C1-kbuild-version-mk.patch"
        assert_exists "${stage_dir}/patches/base/C5-crash-safety.patch"
        assert_exists "${stage_dir}/patches/addon/A1-pcie-primitives.patch"
        assert_exists "${stage_dir}/patches/addon/A5-version-and-toggles.patch"
        assert_exists "${stage_dir}/patches/local/L1-no-suffix-version-string.patch"
        assert_not_exists "${stage_dir}/patches/C1-kbuild-version-mk.patch"
        assert_not_exists "${stage_dir}/patches/A1-pcie-primitives.patch"
        assert_not_exists "${stage_dir}/patches/L1-no-suffix-version-string.patch"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_replaces_overlay_owned_patch_directories() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file preserved_patch_layer_dir
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    preserved_patch_layer_dir='patches-upstream-archive'
    create_fake_repo_with_open_patch_series "$utils_repo"
    mkdir -p "$utils_repo/patches" "$utils_repo/${legacy_patch_layer_dir_name}" "$utils_repo/${preserved_patch_layer_dir}"
    printf 'upstream patch that should be removed\n' >"$utils_repo/patches/upstream-only.patch"
    printf 'upstream local patch that should be removed\n' >"$utils_repo/${legacy_patch_layer_dir_name}/upstream-only.patch"
    printf 'archive patch that should remain\n' >"$utils_repo/${preserved_patch_layer_dir}/keep.patch"
    git -C "$utils_repo" add patches "$legacy_patch_layer_dir_name" "$preserved_patch_layer_dir"
    git -C "$utils_repo" commit -q -m 'add upstream patch directories'

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
         assert_not_exists "${stage_dir}/patches/upstream-only.patch"
        assert_exists "${stage_dir}/${legacy_patch_layer_dir_name}/upstream-only.patch"
        assert_exists "${stage_dir}/${preserved_patch_layer_dir}/keep.patch"
        assert_exists "${stage_dir}/patches/manifest"
        assert_exists "${stage_dir}/patches/base/C1-kbuild-version-mk.patch"
        assert_exists "${stage_dir}/patches/addon/A1-pcie-primitives.patch"
        assert_exists "${stage_dir}/patches/local/L1-no-suffix-version-string.patch"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_fails_when_repo_patch_manifest_is_missing() {
    local tmpdir utils_repo repo_copy stage_dir stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    repo_copy="${tmpdir}/repo-copy"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    create_fake_repo_with_open_patch_series "$utils_repo"
    copy_wrapper_repo_fixture "$repo_copy"
    rm -f -- "${repo_copy}/patches/manifest"

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      run_wrapper_from_repo_copy "$repo_copy" --stage-only "$stage_dir"; then
        printf 'expected stage-only to fail when patches/manifest is missing\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail when patches/manifest is missing"
    assert_contains 'missing repo patch manifest:' "$stderr_file"
}

test_stage_only_fails_when_manifest_row_has_unknown_layer() {
    local tmpdir utils_repo repo_copy stage_dir stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    repo_copy="${tmpdir}/repo-copy"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    create_fake_repo_with_open_patch_series "$utils_repo"
    copy_wrapper_repo_fixture "$repo_copy"
    printf '  Z9-test-bad-layer        weird  -              fork:test\n' >>"${repo_copy}/patches/manifest"

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      run_wrapper_from_repo_copy "$repo_copy" --stage-only "$stage_dir"; then
        printf 'expected stage-only to fail on an unknown manifest layer\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail on an unknown manifest layer"
    assert_contains 'unsupported repo patch layer' "$stderr_file"
}

test_stage_only_fails_when_manifest_row_has_invalid_source_semantics() {
    local tmpdir utils_repo repo_copy stage_dir stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    repo_copy="${tmpdir}/repo-copy"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    create_fake_repo_with_open_patch_series "$utils_repo"
    copy_wrapper_repo_fixture "$repo_copy"
    perl -0pi -e 's/fork:a1-pcie-primitives/repo:a1-pcie-primitives/' "${repo_copy}/patches/manifest"

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      run_wrapper_from_repo_copy "$repo_copy" --stage-only "$stage_dir"; then
        printf 'expected stage-only to fail on invalid manifest source semantics\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail on invalid manifest source semantics"
    assert_contains 'invalid repo patch source for addon layer' "$stderr_file"
}

test_stage_only_fails_when_manifest_entry_is_unresolved() {
    local tmpdir utils_repo repo_copy stage_dir stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    repo_copy="${tmpdir}/repo-copy"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    create_fake_repo_with_open_patch_series "$utils_repo"
    copy_wrapper_repo_fixture "$repo_copy"
    printf '  Z8-does-not-exist        local  -              repo:test\n' >>"${repo_copy}/patches/manifest"

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      run_wrapper_from_repo_copy "$repo_copy" --stage-only "$stage_dir"; then
        printf 'expected stage-only to fail on an unresolved manifest entry\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail on an unresolved manifest entry"
    assert_contains 'missing repo patch for manifest entry Z8-does-not-exist' "$stderr_file"
}

test_stage_only_fails_when_manifest_resolves_no_addon_patches() {
    local tmpdir utils_repo repo_copy stage_dir stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    repo_copy="${tmpdir}/repo-copy"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    create_fake_repo_with_open_patch_series "$utils_repo"
    copy_wrapper_repo_fixture "$repo_copy"
    grep -v ' addon ' "${repo_copy}/patches/manifest" >"${repo_copy}/patches/manifest.new"
    mv "${repo_copy}/patches/manifest.new" "${repo_copy}/patches/manifest"

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      run_wrapper_from_repo_copy "$repo_copy" --stage-only "$stage_dir"; then
        printf 'expected stage-only to fail when the manifest resolves no addon patches\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail when the addon phase is empty"
    assert_contains 'repo patch manifest resolved no addon patches' "$stderr_file"
}

test_stage_only_fails_when_manifest_resolves_no_local_patches() {
    local tmpdir utils_repo repo_copy stage_dir stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    repo_copy="${tmpdir}/repo-copy"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    create_fake_repo_with_open_patch_series "$utils_repo"
    copy_wrapper_repo_fixture "$repo_copy"
    grep -v ' local ' "${repo_copy}/patches/manifest" >"${repo_copy}/patches/manifest.new"
    mv "${repo_copy}/patches/manifest.new" "${repo_copy}/patches/manifest"

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      run_wrapper_from_repo_copy "$repo_copy" --stage-only "$stage_dir"; then
        printf 'expected stage-only to fail when the manifest resolves no local patches\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail when the local phase is empty"
    assert_contains 'repo patch manifest resolved no local patches' "$stderr_file"
}

test_stage_only_generates_manifest_derived_base_addon_and_local_patch_arrays() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    create_fake_repo_with_open_patch_series "$utils_repo"

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_contains 'base_patch_series=(' "${stage_dir}/PKGBUILD"
        assert_contains 'base/C1-kbuild-version-mk.patch' "${stage_dir}/PKGBUILD"
        assert_contains 'base/C5-crash-safety.patch' "${stage_dir}/PKGBUILD"
        assert_contains 'addon_patch_series=(' "${stage_dir}/PKGBUILD"
        assert_contains 'addon/A1-pcie-primitives.patch' "${stage_dir}/PKGBUILD"
        assert_contains 'addon/A5-version-and-toggles.patch' "${stage_dir}/PKGBUILD"
        assert_contains 'local_patch_series=(' "${stage_dir}/PKGBUILD"
        assert_contains 'local/L1-no-suffix-version-string.patch' "${stage_dir}/PKGBUILD"
        assert_line_order 'base/C1-kbuild-version-mk.patch' 'base/C5-crash-safety.patch' "${stage_dir}/PKGBUILD"
        assert_line_order 'base/C5-crash-safety.patch' 'addon/A1-pcie-primitives.patch' "${stage_dir}/PKGBUILD"
        assert_line_order 'addon/A1-pcie-primitives.patch' 'addon/A5-version-and-toggles.patch' "${stage_dir}/PKGBUILD"
        assert_line_order 'addon/A5-version-and-toggles.patch' 'local/L1-no-suffix-version-string.patch' "${stage_dir}/PKGBUILD"
        assert_not_contains 'repo_patch_series=("${repo_patches_dir}"/*.patch)' "${stage_dir}/PKGBUILD"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_preserves_upstream_package_patch_file_content() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    create_fake_repo "$utils_repo" 595.71.05 2
    printf 'upstream systemd patch marker\n' >"${utils_repo}/systemd.patch"
    printf 'upstream ibt patch marker\n' >"${utils_repo}/0002-Add-IBT-support.patch"
    git -C "$utils_repo" add systemd.patch 0002-Add-IBT-support.patch
    git -C "$utils_repo" commit -q -m 'add upstream package patch files'

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_equals 'upstream systemd patch marker' "$(<"${stage_dir}/systemd.patch")" "staged systemd.patch should remain upstream-owned"
        assert_equals 'upstream ibt patch marker' "$(<"${stage_dir}/0002-Add-IBT-support.patch")" "staged 0002-Add-IBT-support.patch should remain upstream-owned"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_preserves_all_upstream_open_patch_entries() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file source_entry_pattern prepare_entry_pattern
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    source_entry_pattern="^[[:space:]]*'systemd\\.patch'[[:space:]]*$"
    prepare_entry_pattern='patch -Np1 -i "\$\{srcdir\}/systemd\.patch" -d "\$\{srcdir\}/\$\{_pkg\}"'

    create_fake_repo_with_open_patch_series "$utils_repo"

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_contains '0002-Add-IBT-support.patch' "${stage_dir}/PKGBUILD"
        assert_contains '0007-extra-open.patch::https://example.invalid/extra-open.patch' "${stage_dir}/PKGBUILD"
        assert_not_matches "$source_entry_pattern" "${stage_dir}/PKGBUILD"
        assert_not_matches "$prepare_entry_pattern" "${stage_dir}/PKGBUILD"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_preserves_upstream_open_patch_entries_after_nested_prepare_brace_group() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file pkgbuild_content
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    pkgbuild_content="$(cat <<'EOF'
pkgbase=nvidia-utils
pkgname=('nvidia-utils' 'nvidia-open-dkms')
pkgver=595.71.05
pkgrel=2
_pkg="NVIDIA-Linux-x86_64-${pkgver}"
_pkg_open="NVIDIA-kernel-module-source-${pkgver}"
source=("https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/${_pkg_open}.tar.xz"
        '0002-Add-IBT-support.patch'
        '0007-extra-open.patch')
sha256sums=('tarball-sha'
            'ibt-sha'
            'extra-sha')
prepare() {
    {
        patch -Np1 -i "${srcdir}/0002-Add-IBT-support.patch" -d "${srcdir}/${_pkg_open}"
    }
    patch -Np1 -i "${srcdir}/0007-extra-open.patch" -d "${srcdir}/${_pkg_open}"
}
package_nvidia-open-dkms() { :; }
EOF
)"
    create_fake_repo_with_pkgbuild_fixture \
        "$utils_repo" \
        'seed nested prepare brace group' \
        "$pkgbuild_content" \
        '0002-Add-IBT-support.patch' 'upstream ibt fixture' \
        '0007-extra-open.patch' 'upstream extra open fixture'

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_contains '0002-Add-IBT-support.patch' "${stage_dir}/PKGBUILD"
        assert_contains '0007-extra-open.patch' "${stage_dir}/PKGBUILD"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_does_not_execute_top_level_pkgbuild_shell() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file side_effect_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    side_effect_file="${tmpdir}/pkgbuild-side-effect"

    create_fake_repo "$utils_repo" 595.71.05 2
    write_fake_pkgbuild "$utils_repo" 595.71.05 2 "printf 'executed\n' >'${side_effect_file}'"
    git -C "$utils_repo" add PKGBUILD
    git -C "$utils_repo" commit -q -m 'add top-level shell side effect'

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_not_exists "$side_effect_file"
        assert_matches "$(dedicated_pkgbuild_pkgname_pattern)" "${stage_dir}/PKGBUILD"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_generates_dedicated_nvidia_open_dkms_pkgbuild() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    create_fake_repo "$utils_repo" 595.71.05 2

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_matches "$(dedicated_pkgbuild_pkgname_pattern)" "${stage_dir}/PKGBUILD"
        assert_not_contains "pkgbase=nvidia-utils" "${stage_dir}/PKGBUILD"
        assert_not_contains "package_nvidia-utils()" "${stage_dir}/PKGBUILD"
        assert_not_contains "package_opencl-nvidia()" "${stage_dir}/PKGBUILD"
        assert_not_contains "package_nvidia-settings()" "${stage_dir}/PKGBUILD"
        assert_not_contains "mhwd-nvidia" "${stage_dir}/PKGBUILD"
        assert_contains 'NVIDIA-kernel-module-source-595.71.05.tar.xz' "${stage_dir}/PKGBUILD"
        assert_not_contains 'NVIDIA-Linux-x86_64-${pkgver}.run' "${stage_dir}/PKGBUILD"
        assert_not_contains '${pkgver}.tar.xz' "${stage_dir}/PKGBUILD"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_fails_when_prepare_references_missing_open_patch_source_entry() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file status pkgbuild_content
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    pkgbuild_content="$(cat <<'EOF'
pkgbase=nvidia-utils
pkgname=('nvidia-utils' 'nvidia-open-dkms')
pkgver=595.71.05
pkgrel=2
_pkg="NVIDIA-Linux-x86_64-${pkgver}"
_pkg_open="NVIDIA-kernel-module-source-${pkgver}"
source=("https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/${_pkg_open}.tar.xz"
        '0002-Add-IBT-support.patch')
sha256sums=('tarball-sha'
            'ibt-sha')
prepare() {
    patch -Np1 -i "${srcdir}/0002-Add-IBT-support.patch" -d "${srcdir}/${_pkg_open}"
    patch -Np1 -i "${srcdir}/0007-extra-open.patch" -d "${srcdir}/${_pkg_open}"
}
package_nvidia-open-dkms() { :; }
EOF
)"
    create_fake_repo_with_pkgbuild_fixture \
        "$utils_repo" \
        'seed missing open patch source entry' \
        "$pkgbuild_content" \
        '0002-Add-IBT-support.patch' 'upstream ibt fixture'

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        printf 'expected stage-only to fail when prepare() references an open patch missing from source=()\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail when an open patch is missing from source=()"
    assert_contains 'missing required upstream source entry: 0007-extra-open.patch' "$stderr_file"
}

test_stage_only_accepts_patch_arrays_closed_before_trailing_comment() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file pkgbuild_content
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    pkgbuild_content="$(cat <<'EOF'
pkgbase=nvidia-utils
pkgname=('nvidia-utils' 'nvidia-open-dkms')
pkgver=595.71.05
pkgrel=2
_pkg_open="NVIDIA-kernel-module-source-${pkgver}"
source=("https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/${_pkg_open}.tar.xz" '0002-Add-IBT-support.patch' '0007-extra-open.patch') # trailing comment
sha256sums=('tarball-sha' 'ibt-sha' 'extra-sha') # trailing comment
prepare() {
    patch -Np1 -i "${srcdir}/0002-Add-IBT-support.patch" -d "${srcdir}/${_pkg_open}"
    patch -Np1 -i "${srcdir}/0007-extra-open.patch" -d "${srcdir}/${_pkg_open}"
}
package_nvidia-open-dkms() { :; }
EOF
)"
    create_fake_repo_with_pkgbuild_fixture \
        "$utils_repo" \
        'seed trailing comment arrays' \
        "$pkgbuild_content" \
        '0002-Add-IBT-support.patch' 'upstream ibt fixture' \
        '0007-extra-open.patch' 'upstream extra open fixture'

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_contains '0002-Add-IBT-support.patch' "${stage_dir}/PKGBUILD"
        assert_contains '0007-extra-open.patch' "${stage_dir}/PKGBUILD"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_preserves_aliased_upstream_open_patch_source_entry() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file pkgbuild_content
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    pkgbuild_content="$(cat <<'EOF'
pkgbase=nvidia-utils
pkgname=('nvidia-utils' 'nvidia-open-dkms')
pkgver=595.71.05
pkgrel=2
_pkg_open="NVIDIA-kernel-module-source-${pkgver}"
source=("https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/${_pkg_open}.tar.xz"
        "0007-extra-open.patch::https://example.invalid/$HOME.patch")
sha256sums=('tarball-sha'
            'extra-sha')
prepare() {
    patch -Np1 -i "${srcdir}/0007-extra-open.patch" -d "${srcdir}/${_pkg_open}"
}
package_nvidia-open-dkms() { :; }
EOF
)"
    create_fake_repo_with_pkgbuild_fixture \
        "$utils_repo" \
        'seed aliased open patch source entry' \
        "$pkgbuild_content"

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_not_contains '"0007-extra-open.patch::https://example.invalid/$HOME.patch"' "${stage_dir}/PKGBUILD"
        assert_contains "'0007-extra-open.patch::https://example.invalid/\$HOME.patch'" "${stage_dir}/PKGBUILD"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_accepts_unbraced_scalar_expansion_in_upstream_source_entries() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file pkgbuild_content
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    pkgbuild_content="$(cat <<'EOF'
pkgbase=nvidia-utils
pkgname=('nvidia-utils' 'nvidia-open-dkms')
pkgver=595.71.05
pkgrel=2
_pkg_open="NVIDIA-kernel-module-source-$pkgver"
source=("https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/$_pkg_open.tar.xz"
        '0007-extra-open.patch')
sha256sums=('tarball-sha'
            'extra-sha')
prepare() {
    patch -Np1 -i "${srcdir}/0007-extra-open.patch" -d "${srcdir}/${_pkg_open}"
}
package_nvidia-open-dkms() { :; }
EOF
)"
    create_fake_repo_with_pkgbuild_fixture \
        "$utils_repo" \
        'seed unbraced scalar expansion source entry' \
        "$pkgbuild_content" \
        '0007-extra-open.patch' 'upstream extra open fixture'

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_contains 'NVIDIA-kernel-module-source-595.71.05.tar.xz' "${stage_dir}/PKGBUILD"
        assert_contains '0007-extra-open.patch' "${stage_dir}/PKGBUILD"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_preserves_multiline_upstream_open_patch_invocation() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file pkgbuild_content
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    pkgbuild_content="$(cat <<'EOF'
pkgbase=nvidia-utils
pkgname=('nvidia-utils' 'nvidia-open-dkms')
pkgver=595.71.05
pkgrel=2
_pkg_open="NVIDIA-kernel-module-source-${pkgver}"
source=("https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/${_pkg_open}.tar.xz"
        '0002-Add-IBT-support.patch'
        '0007-extra-open.patch')
sha256sums=('tarball-sha'
            'ibt-sha'
            'extra-sha')
prepare() {
    patch -Np1 \
        -i "${srcdir}/0002-Add-IBT-support.patch" \
        -d "${srcdir}/${_pkg_open}"
    patch -Np1 -i "${srcdir}/0007-extra-open.patch" -d "${srcdir}/${_pkg_open}"
}
package_nvidia-open-dkms() { :; }
EOF
)"
    create_fake_repo_with_pkgbuild_fixture \
        "$utils_repo" \
        'seed multiline prepare patch invocation' \
        "$pkgbuild_content" \
        '0002-Add-IBT-support.patch' 'upstream ibt fixture' \
        '0007-extra-open.patch' 'upstream extra open fixture'

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_contains '0002-Add-IBT-support.patch' "${stage_dir}/PKGBUILD"
        assert_contains '0007-extra-open.patch' "${stage_dir}/PKGBUILD"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_fails_when_referenced_open_patch_lacks_matching_sha256sum() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file status pkgbuild_content
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    pkgbuild_content="$(cat <<'EOF'
pkgbase=nvidia-utils
pkgname=('nvidia-utils' 'nvidia-open-dkms')
pkgver=595.71.05
pkgrel=2
_pkg_open="NVIDIA-kernel-module-source-${pkgver}"
source=("https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/${_pkg_open}.tar.xz"
        '0002-Add-IBT-support.patch'
        '0007-extra-open.patch')
sha256sums=('tarball-sha'
            'ibt-sha')
prepare() {
    patch -Np1 -i "${srcdir}/0002-Add-IBT-support.patch" -d "${srcdir}/${_pkg_open}"
    patch -Np1 -i "${srcdir}/0007-extra-open.patch" -d "${srcdir}/${_pkg_open}"
}
package_nvidia-open-dkms() { :; }
EOF
)"
    create_fake_repo_with_pkgbuild_fixture \
        "$utils_repo" \
        'seed missing open patch checksum' \
        "$pkgbuild_content" \
        '0002-Add-IBT-support.patch' 'upstream ibt fixture' \
        '0007-extra-open.patch' 'upstream extra open fixture'

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        printf 'expected stage-only to fail when a referenced open patch lacks a matching sha256sum\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail when a referenced open patch has no matching checksum"
    assert_contains 'missing required upstream sha256sum for source entry: 0007-extra-open.patch' "$stderr_file"
}

test_dedicated_pkgbuild_pkgname_matcher_rejects_mismatched_quotes() {
    local tmpdir pkgbuild_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    pkgbuild_file="${tmpdir}/PKGBUILD"

    printf 'pkgname='\''nvidia-open-dkms"\n' >"$pkgbuild_file"

    assert_not_matches "$(dedicated_pkgbuild_pkgname_pattern)" "$pkgbuild_file"
}

test_stage_only_uses_anchored_pkgver_and_pkgrel_matches() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    create_fake_repo "$utils_repo" 595.71.05 2
    write_fake_pkgbuild "$utils_repo" 595.71.05 2 '# target commit marker'
    printf 'matched target commit\n' >"${utils_repo}/selected-commit.marker"
    git -C "$utils_repo" add PKGBUILD selected-commit.marker
    git -C "$utils_repo" commit -q -m 'mark target commit'
    commit_fake_repo_version "$utils_repo" 600.10.01 1 '# pkgver=595.71.05\n# pkgrel=2'

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        assert_exists "${stage_dir}/selected-commit.marker"
        assert_contains 'pkgver=595.71.05' "${stage_dir}/PKGBUILD"
        assert_contains 'pkgrel=2' "${stage_dir}/PKGBUILD"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_stage_only_rejects_existing_nonempty_destination() {
    local tmpdir utils_repo stage_dir stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    create_fake_repo "$utils_repo" 595.71.05 2
    mkdir -p "$stage_dir"
    printf 'keep me\n' >"${stage_dir}/user-file"

    if MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --stage-only "$stage_dir"; then
        printf 'expected --stage-only to reject an existing non-empty directory\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail for an existing non-empty stage directory"
    assert_contains 'already exists and is not empty' "$stderr_file"
    assert_contains 'keep me' "${stage_dir}/user-file"
}

test_default_execution_cleans_up_temp_stage_dir_on_failure() {
    local tmpdir utils_repo stdout_file stderr_file fake_bin status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    fake_bin="${tmpdir}/bin"
    create_fake_repo "$utils_repo" 595.71.05 2
    create_fake_makepkg "$fake_bin"

    if TMPDIR="$tmpdir" \
      PATH="${fake_bin}:$PATH" \
      MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper"; then
        printf 'expected wrapper to fail when makepkg fails\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should return makepkg failure status"
    assert_contains 'fake makepkg failure' "$stderr_file"
    assert_no_leaked_mktemp_dirs "$tmpdir"
}

test_default_target_version_uses_host_package_query() {
    local tmpdir utils_repo fake_bin stdout_file stderr_file output
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    fake_bin="${tmpdir}/bin"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    create_fake_repo "$utils_repo" 595.71.05 2
    update_fake_repo_version "$utils_repo" 600.10.01 1
    create_fake_pacman "$fake_bin" 600.10.01-1

    if PATH="${fake_bin}:$PATH" \
        MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
        run_wrapper_capture "$stdout_file" "$stderr_file" \
        bash "$wrapper" --print-source-repo; then
        output="$(<"$stdout_file")"
        assert_equals "nvidia-utils" "$output" "host package query should determine the selected target version"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_default_target_version_prefers_upstream_managed_nvidia_utils_version() {
    local tmpdir utils_repo fake_bin stage_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    fake_bin="${tmpdir}/bin"
    stage_dir="${tmpdir}/stage"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    create_fake_repo "$utils_repo" 595.71.05 2
    create_fake_pacman_with_installed_versions "$fake_bin" 595.71.05-100 595.71.05-2

    if PATH="${fake_bin}:$PATH" \
        MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
        run_wrapper_capture "$stdout_file" "$stderr_file" \
        bash "$wrapper" --stage-only "$stage_dir"; then
        assert_exists "${stage_dir}/PKGBUILD"
        assert_contains 'pkgver=595.71.05' "${stage_dir}/PKGBUILD"
        assert_contains 'pkgrel=2' "${stage_dir}/PKGBUILD"
        assert_exists "${stage_dir}/0002-Add-IBT-support.patch"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_explicit_target_version_allows_new_upstream_version() {
    local tmpdir utils_repo stdout_file stderr_file output
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    utils_repo="${tmpdir}/nvidia-utils"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    create_fake_repo "$utils_repo" 595.71.05 2
    update_fake_repo_version "$utils_repo" 600.10.01 1

    if MANJARO_TARGET_VERSION=600.10.01-1 \
        MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
        run_wrapper_capture "$stdout_file" "$stderr_file" \
        bash "$wrapper" --print-source-repo; then
        output="$(<"$stdout_file")"
        assert_equals "nvidia-utils" "$output" "wrapper should allow a newer upstream version"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_default_execution_preserves_root_artifact_and_handles_makepkg_without_pkg_flag() {
    local tmpdir utils_repo fake_bin stdout_file stderr_file record_file artifact_name artifact_path
    tmpdir="$(mktemp -d)"
    utils_repo="${tmpdir}/nvidia-utils"
    fake_bin="${tmpdir}/bin"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    record_file="${tmpdir}/args"
    artifact_name='nvidia-open-dkms-599.99.99-7-x86_64.pkg.tar.zst'
    artifact_path="${repo_root}/${artifact_name}"
    trap "rm -rf -- '$tmpdir'; rm -f -- '$artifact_path'" RETURN
    create_fake_repo "$utils_repo" 595.71.05 2
    create_fake_makepkg_without_pkg_support "$fake_bin" "$record_file" "$artifact_name"

    rm -f -- "$artifact_path"

    if PATH="${fake_bin}:$PATH" \
      MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper"; then
        assert_contains '-Cfs' "$record_file"
        assert_not_contains '--pkg' "$record_file"
        assert_exists "$artifact_path"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_packagelist_succeeds_without_build_artifacts() {
    local tmpdir utils_repo fake_bin stdout_file stderr_file record_file artifact_name artifact_path
    tmpdir="$(mktemp -d)"
    utils_repo="${tmpdir}/nvidia-utils"
    fake_bin="${tmpdir}/bin"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    record_file="${tmpdir}/args"
    artifact_name='nvidia-open-dkms-595.71.05-2-x86_64.pkg.tar.zst'
    artifact_path="${repo_root}/${artifact_name}"
    trap "rm -rf -- '$tmpdir'; rm -f -- '$artifact_path'" RETURN
    create_fake_repo "$utils_repo" 595.71.05 2
    create_fake_makepkg_query_only "$fake_bin" "$record_file" "$artifact_name"
    rm -f -- "$artifact_path"

    if PATH="${fake_bin}:$PATH" \
      MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --packagelist; then
        assert_not_contains '--pkg' "$record_file"
        assert_contains '--packagelist' "$record_file"
        assert_contains "${artifact_name}" "$stdout_file"
        [[ ! -e "$artifact_path" ]] || {
            printf 'query-only makepkg unexpectedly moved artifact to repo root: %s\n' "$artifact_path" >&2
            return 1
        }
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

test_source_mode_fails_closed() {
    local tmpdir utils_repo fake_bin stdout_file stderr_file record_file artifact_name status
    tmpdir="$(mktemp -d)"
    utils_repo="${tmpdir}/nvidia-utils"
    fake_bin="${tmpdir}/bin"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    record_file="${tmpdir}/args"
    artifact_name='nvidia-utils-595.71.05-2.src.tar.zst'
    trap "rm -rf -- '$tmpdir'" RETURN
    create_fake_repo "$utils_repo" 595.71.05 2
    create_fake_makepkg_source_mode "$fake_bin" "$record_file" "$artifact_name"

    if PATH="${fake_bin}:$PATH" \
      MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" --source; then
        printf 'expected wrapper to reject --source\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail closed for --source"
    assert_contains 'source package modes are not supported by this wrapper' "$stderr_file"
    if [[ -e "$record_file" ]]; then
        printf 'makepkg should not have been invoked for --source\n' >&2
        return 1
    fi
}

test_source_mode_bundle_fails_closed() {
    local tmpdir utils_repo fake_bin stdout_file stderr_file record_file artifact_name status
    tmpdir="$(mktemp -d)"
    utils_repo="${tmpdir}/nvidia-utils"
    fake_bin="${tmpdir}/bin"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    record_file="${tmpdir}/args"
    artifact_name='nvidia-utils-595.71.05-2.src.tar.zst'
    trap "rm -rf -- '$tmpdir'" RETURN
    create_fake_repo "$utils_repo" 595.71.05 2
    create_fake_makepkg_source_mode "$fake_bin" "$record_file" "$artifact_name"

    if PATH="${fake_bin}:$PATH" \
      MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper" -Sg; then
        printf 'expected wrapper to reject -Sg\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals "1" "$status" "wrapper should fail closed for bundled source mode"
    assert_contains 'source package modes are not supported by this wrapper' "$stderr_file"
    if [[ -e "$record_file" ]]; then
        printf 'makepkg should not have been invoked for -Sg\n' >&2
        return 1
    fi
}

test_default_execution_uses_staged_overlay_as_repo_root() {
    local tmpdir utils_repo fake_bin stdout_file stderr_file repo_root_file cwd_file artifact_name
    tmpdir="$(mktemp -d)"
    utils_repo="${tmpdir}/nvidia-utils"
    fake_bin="${tmpdir}/bin"
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    repo_root_file="${tmpdir}/repo-root"
    cwd_file="${tmpdir}/cwd"
    artifact_name='nvidia-open-dkms-595.71.05-2-x86_64.pkg.tar.zst'
    trap "rm -rf -- '$tmpdir'; rm -f -- '${repo_root}/${artifact_name}'" RETURN
    create_fake_repo "$utils_repo" 595.71.05 2
    create_fake_makepkg_records_repo_root "$fake_bin" "$repo_root_file" "$cwd_file" "$artifact_name"
    rm -f -- "${repo_root}/${artifact_name}"

    if PATH="${fake_bin}:$PATH" \
      MANJARO_TARGET_VERSION=595.71.05-2 \
      MANJARO_NVIDIA_UTILS_REPO="${utils_repo}" \
      run_wrapper_capture "$stdout_file" "$stderr_file" \
      bash "$wrapper"; then
        assert_equals "$(<"$cwd_file")" "$(<"$repo_root_file")" "wrapper should point AORUS_REPO_ROOT at staged tree"
        return 0
    fi

    printf 'wrapper stderr:\n' >&2
    cat "$stderr_file" >&2
    return 1
}

main() {
    test_assert_line_order_reports_missing_patterns_without_aborting_shell
    test_copy_wrapper_repo_fixture_excludes_git_without_rsync_dependency
    test_print_source_repo_prefers_nvidia_utils
    test_print_source_repo_requires_nvidia_utils_match
    test_print_source_repo_surfaces_checkout_failures
    test_stage_only_stages_manifest_base_addon_and_local_patch_tree
    test_stage_only_replaces_overlay_owned_patch_directories
    test_dedicated_pkgbuild_pkgname_matcher_rejects_mismatched_quotes
    test_stage_only_preserves_upstream_package_patch_file_content
    test_stage_only_preserves_all_upstream_open_patch_entries
    test_stage_only_preserves_upstream_open_patch_entries_after_nested_prepare_brace_group
    test_stage_only_fails_when_repo_patch_manifest_is_missing
    test_stage_only_fails_when_manifest_row_has_unknown_layer
    test_stage_only_fails_when_manifest_row_has_invalid_source_semantics
    test_stage_only_fails_when_manifest_entry_is_unresolved
    test_stage_only_fails_when_manifest_resolves_no_addon_patches
    test_stage_only_fails_when_manifest_resolves_no_local_patches
    test_stage_only_generates_manifest_derived_base_addon_and_local_patch_arrays
    test_stage_only_does_not_execute_top_level_pkgbuild_shell
    test_stage_only_generates_dedicated_nvidia_open_dkms_pkgbuild
    test_stage_only_fails_when_prepare_references_missing_open_patch_source_entry
    test_stage_only_accepts_patch_arrays_closed_before_trailing_comment
    test_stage_only_preserves_aliased_upstream_open_patch_source_entry
    test_stage_only_accepts_unbraced_scalar_expansion_in_upstream_source_entries
    test_stage_only_preserves_multiline_upstream_open_patch_invocation
    test_stage_only_fails_when_referenced_open_patch_lacks_matching_sha256sum
    test_stage_only_uses_anchored_pkgver_and_pkgrel_matches
    test_stage_only_rejects_existing_nonempty_destination
    test_default_execution_cleans_up_temp_stage_dir_on_failure
    test_default_target_version_uses_host_package_query
    test_default_target_version_prefers_upstream_managed_nvidia_utils_version
    test_explicit_target_version_allows_new_upstream_version
    test_default_execution_preserves_root_artifact_and_handles_makepkg_without_pkg_flag
    test_packagelist_succeeds_without_build_artifacts
    test_source_mode_bundle_fails_closed
    test_source_mode_fails_closed
    test_default_execution_uses_staged_overlay_as_repo_root
}

main "$@"
