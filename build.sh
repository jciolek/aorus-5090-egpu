#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

nvidia_utils_repo_default="https://gitlab.manjaro.org/packages/extra/nvidia-utils.git"

checkout_dir=''
stage_dir=''
preserve_stage_dir=0

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

extract_pkgbuild_assignment() {
    local key="$1"

    awk -v key="$key" '
        /^[[:space:]]*#/ { next }
        $0 ~ "^[[:space:]]*" key "=" {
            sub("^[[:space:]]*" key "=", "", $0)
            print
            exit
        }
    '
}

cleanup() {
    if [[ -n "$checkout_dir" ]]; then
        rm -rf -- "$checkout_dir"
    fi
    if [[ "$preserve_stage_dir" -eq 0 && -n "$stage_dir" ]]; then
        rm -rf -- "$stage_dir"
    fi
}

trap cleanup EXIT

detect_target_version() {
    if [[ -n "${MANJARO_TARGET_VERSION-}" ]]; then
        printf '%s\n' "${MANJARO_TARGET_VERSION}"
        return
    fi

    if pacman -Q nvidia-utils >/dev/null 2>&1; then
        pacman -Q nvidia-utils | awk '{print $2}'
        return
    fi
    if pacman -Q nvidia-open-dkms >/dev/null 2>&1; then
        pacman -Q nvidia-open-dkms | awk '{print $2}'
        return
    fi
    die 'could not determine target version; set MANJARO_TARGET_VERSION=<pkgver-pkgrel>'
}

find_matching_commit() {
    local repo_dir="$1"
    local version="$2"
    local pkgver pkgrel actual_pkgver actual_pkgrel
    pkgver="${version%-*}"
    pkgrel="${version##*-}"

    git -C "$repo_dir" log --format='%H' | while read -r sha; do
        local pkgbuild_text
        pkgbuild_text="$(git -C "$repo_dir" show "${sha}:PKGBUILD" 2>/dev/null || true)"
        [[ -n "$pkgbuild_text" ]] || continue
        actual_pkgver="$(extract_pkgbuild_assignment pkgver <<<"$pkgbuild_text" || true)"
        actual_pkgrel="$(extract_pkgbuild_assignment pkgrel <<<"$pkgbuild_text" || true)"
        if [[ "$actual_pkgver" == "$pkgver" && "$actual_pkgrel" == "$pkgrel" ]]; then
            printf '%s\n' "$sha"
            break
        fi
    done
}

extract_upstream_source_tuple() {
    local pkgbuild_path="$1"
    local wanted_basename="$2"
    local source_lines sums_lines
    local -a source_entries sha_entries
    local i entry base

    mapfile -t source_lines < <(awk '
        /^[[:space:]]*source=\(/ {
            sub(/^[[:space:]]*source=\(/, "", $0)
            collecting=1
        }
        collecting {
            line=$0
            closing=(line ~ /\)[[:space:]]*(#[^\n]*)?$/)
            sub(/\)[[:space:]]*(#[^\n]*)?$/, "", line)
            print line
            if (closing) {
                exit
            }
        }
    ' "$pkgbuild_path")
    mapfile -t sums_lines < <(awk '
        /^[[:space:]]*sha256sums=\(/ {
            sub(/^[[:space:]]*sha256sums=\(/, "", $0)
            collecting=1
        }
        collecting {
            line=$0
            closing=(line ~ /\)[[:space:]]*(#[^\n]*)?$/)
            sub(/\)[[:space:]]*(#[^\n]*)?$/, "", line)
            print line
            if (closing) {
                exit
            }
        }
    ' "$pkgbuild_path")

    mapfile -t source_entries < <(printf '%s\n' "${source_lines[@]}" | grep -oE "'[^']*'|\"[^\"]*\"")
    mapfile -t sha_entries < <(printf '%s\n' "${sums_lines[@]}" | grep -oE "'[^']*'|\"[^\"]*\"")

    for i in "${!source_entries[@]}"; do
        entry="$(_strip_shell_quotes "${source_entries[$i]}")"
        entry="$(_expand_pkgbuild_value "$pkgbuild_path" "$entry")"
        base="${entry%%::*}"
        base="${base##*/}"
        if [[ "$base" == "$wanted_basename" ]]; then
            if ((i >= ${#sha_entries[@]})); then
                printf 'missing required upstream sha256sum for source entry: %s\n' "$wanted_basename" >&2
                return 1
            fi
            printf '%s\t%s\n' "$entry" "$(_strip_shell_quotes "${sha_entries[$i]}")"
            return 0
        fi
    done

    return 1
}

_expand_pkgbuild_value() {
    local pkgbuild_path="$1"
    local value="$2"
    local key token simple_token resolved

    for key in _pkg_open pkgver pkgrel _pkg; do
        token="\${${key}}"
        if [[ "$value" == *"$token"* ]]; then
            resolved="$(_extract_pkgbuild_scalar "$pkgbuild_path" "$key")"
            value="${value//$token/$resolved}"
        fi

        simple_token='$'"$key"
        if [[ "$value" == *"$simple_token"* ]]; then
            resolved="$(_extract_pkgbuild_scalar "$pkgbuild_path" "$key")"
            value="${value//$simple_token/$resolved}"
        fi
    done

    printf '%s\n' "$value"
}

extract_upstream_open_patch_basenames() {
    local pkgbuild_path="$1"

    awk '
        function update_depth(text, opens, closes) {
            opens = gsub(/\{/, "{", text)
            closes = gsub(/\}/, "}", text)
            brace_depth += opens - closes
        }

        function flush_statement(      normalized, line) {
            normalized = statement
            gsub(/[[:space:]]+/, " ", normalized)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", normalized)

            if (normalized ~ /patch[[:space:]].*-i[[:space:]]*"\$\{srcdir\}\// &&
                normalized ~ /-d[[:space:]]*"\$\{srcdir\}\/\$\{_pkg_open\}"/) {
                line = normalized
                sub(/^.*-i[[:space:]]*"\$\{srcdir\}\//, "", line)
                sub(/".*$/, "", line)
                print line
            }

            statement = ""
        }

        /^[[:space:]]*prepare\(\)[[:space:]]*\{/ {
            in_prepare=1
            brace_depth=1
            next
        }
        !in_prepare { next }

        {
            statement = statement $0
            if ($0 ~ /\\[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, " ", statement)
            } else {
                flush_statement()
            }
        }

        {
            update_depth($0)
            if (brace_depth == 0) {
                if (statement != "") {
                    flush_statement()
                }
                exit
            }
        }
    ' "$pkgbuild_path"
}

build_shell_array_assignment() {
    local name="$1"
    local value
    shift

    printf '%s=(' "$name"
    if (($# == 0)); then
        printf ')\n'
        return
    fi

    value="$1"
    printf '%s\n' "${value@Q}"
    shift
    for value in "$@"; do
        printf '        %s\n' "${value@Q}"
    done
    printf ')\n'
}

_extract_pkgbuild_scalar() {
    local pkgbuild_path="$1"
    local key="$2"
    local value

    value="$(extract_pkgbuild_assignment "$key" <"$pkgbuild_path")"
    value="$(_strip_shell_quotes "$value")"
    value="${value//$'\n'/}"
    value="$(_expand_pkgbuild_value "$pkgbuild_path" "$value")"
    printf '%s\n' "$value"
}

_strip_shell_quotes() {
    local value="$1"

    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s\n' "$value"
}

collect_repo_manifest_patch_series() {
    local repo_patches_dir="$1"
    local -n base_out="$2"
    local -n addon_out="$3"
    local -n local_out="$4"
    local manifest_path="${repo_patches_dir}/manifest"
    local line id layer upstreamed_in source extra rel_path

    [[ -f "$manifest_path" ]] || die "missing repo patch manifest: ${manifest_path}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        read -r id layer upstreamed_in source extra <<<"$line"

        [[ "$id" == "id" && "$layer" == "layer" ]] && continue

        if [[ -n "${extra-}" || -z "$id" || -z "$layer" || -z "$upstreamed_in" || -z "$source" ]]; then
            die "malformed repo patch manifest row in ${manifest_path}: ${line}"
        fi

        case "$layer" in
            base|addon|local) ;;
            *) die "unsupported repo patch layer in ${manifest_path}: ${layer}" ;;
        esac

        case "$layer" in
            base|addon)
                [[ "$source" == fork:* ]] ||
                    die "invalid repo patch source for ${layer} layer in ${manifest_path}: ${source}"
                ;;
            local)
                [[ "$source" == repo:* ]] ||
                    die "invalid repo patch source for local layer in ${manifest_path}: ${source}"
                ;;
        esac

        rel_path="${layer}/${id}.patch"
        [[ -f "${repo_patches_dir}/${rel_path}" ]] || \
            die "missing repo patch for manifest entry ${id}: ${repo_patches_dir}/${rel_path}"

        case "$layer" in
            base) base_out+=("$rel_path") ;;
            addon) addon_out+=("$rel_path") ;;
            local) local_out+=("$rel_path") ;;
        esac
    done <"$manifest_path"

    ((${#base_out[@]} > 0)) || die "repo patch manifest resolved no base patches from ${manifest_path}"
    ((${#addon_out[@]} > 0)) || die "repo patch manifest resolved no addon patches from ${manifest_path}"
    ((${#local_out[@]} > 0)) || die "repo patch manifest resolved no local patches from ${manifest_path}"
}

rewrite_stage_pkgbuild_for_open_dkms() {
    local pkgbuild_path="$1"
    local pkgver pkgrel pkg_open tarball_entry tarball_sha tuple
    local patch_name patch_entry patch_sha
    local source_block sha_block upstream_patch_block base_patch_block addon_patch_block local_patch_block
    local -a upstream_patch_names=()
    local -a upstream_patch_entries=()
    local -a upstream_patch_shas=()
    local -a repo_base_patch_series=()
    local -a repo_addon_patch_series=()
    local -a repo_local_patch_series=()

    pkgver="$(_extract_pkgbuild_scalar "$pkgbuild_path" pkgver)"
    pkgrel="$(_extract_pkgbuild_scalar "$pkgbuild_path" pkgrel)"
    pkg_open="$(_extract_pkgbuild_scalar "$pkgbuild_path" _pkg_open)"
    tuple="$(extract_upstream_source_tuple "$pkgbuild_path" "${pkg_open}.tar.xz")" ||
        die "missing required upstream source entry: ${pkg_open}.tar.xz"
    IFS=$'\t' read -r tarball_entry tarball_sha <<<"$tuple"

    mapfile -t upstream_patch_names < <(extract_upstream_open_patch_basenames "$pkgbuild_path")
    for patch_name in "${upstream_patch_names[@]}"; do
        tuple="$(extract_upstream_source_tuple "$pkgbuild_path" "$patch_name")" ||
            die "missing required upstream source entry: $patch_name"
        IFS=$'\t' read -r patch_entry patch_sha <<<"$tuple"
        upstream_patch_entries+=("$patch_entry")
        upstream_patch_shas+=("$patch_sha")
    done

    collect_repo_manifest_patch_series "${repo_root}/patches" repo_base_patch_series repo_addon_patch_series repo_local_patch_series

    source_block="$(build_shell_array_assignment source "$tarball_entry" "${upstream_patch_entries[@]}")"
    sha_block="$(build_shell_array_assignment sha256sums "$tarball_sha" "${upstream_patch_shas[@]}")"
    upstream_patch_block="$(build_shell_array_assignment upstream_patch_series "${upstream_patch_names[@]}")"
    base_patch_block="$(build_shell_array_assignment base_patch_series "${repo_base_patch_series[@]}")"
    addon_patch_block="$(build_shell_array_assignment addon_patch_series "${repo_addon_patch_series[@]}")"
    local_patch_block="$(build_shell_array_assignment local_patch_series "${repo_local_patch_series[@]}")"

    cat >"$pkgbuild_path" <<EOF
pkgname=nvidia-open-dkms
pkgver=${pkgver}
pkgrel=${pkgrel}
pkgdesc="NVIDIA open kernel modules - module sources"
arch=('x86_64')
url="http://www.nvidia.com/"
license=('MIT AND GPL-2.0-only')
depends=('dkms' "nvidia-utils=${pkgver}" 'libglvnd')
provides=('nvidia-open' 'NVIDIA-MODULE')
conflicts=('nvidia-open' 'NVIDIA-MODULE')
options=('!strip')
_pkg_open="NVIDIA-kernel-module-source-${pkgver}"
${source_block}
${sha_block}

prepare() {
    local repo_root repo_patches_dir patch
${upstream_patch_block}
${base_patch_block}
${addon_patch_block}
${local_patch_block}

    for patch in "\${upstream_patch_series[@]}"; do
        patch -Np1 -i "\${srcdir}/\${patch}" -d "\${srcdir}/\${_pkg_open}"
    done

    sed -i "s/^  HOSTNAME.*/  HOSTNAME = echo manjarolinux/" "\${srcdir}/\${_pkg_open}/utils.mk"
    sed -i "s/^WHOAMI.*/WHOAMI = echo manjarolinux-builder/" "\${srcdir}/\${_pkg_open}/utils.mk"
    sed -i "s/^DATE.*/DATE = date -r version.mk/" "\${srcdir}/\${_pkg_open}/utils.mk"

    sed -i "s/__VERSION_STRING/${pkgver}/" "\${srcdir}/\${_pkg_open}/kernel-open/dkms.conf"
    sed -i 's/__JOBS/`nproc`/' "\${srcdir}/\${_pkg_open}/kernel-open/dkms.conf"
    sed -i 's/__EXCLUDE_MODULES//' "\${srcdir}/\${_pkg_open}/kernel-open/dkms.conf"
    sed -i 's/__DKMS_MODULES//' "\${srcdir}/\${_pkg_open}/kernel-open/dkms.conf"
    sed -i 's/NV_EXCLUDE_BUILD_MODULES/IGNORE_PREEMPT_RT_PRESENCE=1 NV_EXCLUDE_BUILD_MODULES/' "\${srcdir}/\${_pkg_open}/kernel-open/dkms.conf"
    cat >>"\${srcdir}/\${_pkg_open}/kernel-open/dkms.conf" <<'DKMS_MODULES_EOF'
BUILT_MODULE_NAME[0]="nvidia"
BUILT_MODULE_LOCATION[0]="kernel-open"
DEST_MODULE_LOCATION[0]="/kernel/drivers/video"
BUILT_MODULE_NAME[1]="nvidia-uvm"
BUILT_MODULE_LOCATION[1]="kernel-open"
DEST_MODULE_LOCATION[1]="/kernel/drivers/video"
BUILT_MODULE_NAME[2]="nvidia-modeset"
BUILT_MODULE_LOCATION[2]="kernel-open"
DEST_MODULE_LOCATION[2]="/kernel/drivers/video"
BUILT_MODULE_NAME[3]="nvidia-drm"
BUILT_MODULE_LOCATION[3]="kernel-open"
DEST_MODULE_LOCATION[3]="/kernel/drivers/video"
BUILT_MODULE_NAME[4]="nvidia-peermem"
BUILT_MODULE_LOCATION[4]="kernel-open"
DEST_MODULE_LOCATION[4]="/kernel/drivers/video"
DKMS_MODULES_EOF

    repo_root="\${AORUS_REPO_ROOT:-\$(cd -- "\${startdir}" && pwd)}"
    repo_patches_dir="\${repo_root}/patches"

    for patch in "\${base_patch_series[@]}"; do
        patch -Np1 -i "\${repo_patches_dir}/\${patch}" -d "\${srcdir}/\${_pkg_open}"
    done

    for patch in "\${addon_patch_series[@]}"; do
        patch -Np1 -i "\${repo_patches_dir}/\${patch}" -d "\${srcdir}/\${_pkg_open}"
    done

    for patch in "\${local_patch_series[@]}"; do
        patch -Np1 -i "\${repo_patches_dir}/\${patch}" -d "\${srcdir}/\${_pkg_open}"
    done
}

package() {
    install -dm755 "\${pkgdir}/usr/src"
    cp -dr --no-preserve='ownership' "\${srcdir}/\${_pkg_open}" "\${pkgdir}/usr/src/nvidia-${pkgver}"
    mv "\${pkgdir}/usr/src/nvidia-${pkgver}/kernel-open/dkms.conf" "\${pkgdir}/usr/src/nvidia-${pkgver}/dkms.conf"
    install -Dm644 "\${srcdir}/\${_pkg_open}/COPYING" "\${pkgdir}/usr/share/licenses/\${pkgname}/LICENSE"
}
EOF
}

prepare_stage_dir() {
    local stage_dir="$1"
    local -a existing_entries=()

    if [[ ! -e "$stage_dir" ]]; then
        mkdir -p "$stage_dir"
        return
    fi

    [[ -d "$stage_dir" ]] || die "stage directory path already exists and is not a directory: $stage_dir"

    shopt -s nullglob dotglob
    existing_entries=("$stage_dir"/*)
    shopt -u nullglob dotglob
    ((${#existing_entries[@]} == 0)) || die "stage directory already exists and is not empty: $stage_dir"
}

resolve_repo_url() {
    local repo_name="$1"
    case "$repo_name" in
        nvidia-utils) printf '%s\n' "${MANJARO_NVIDIA_UTILS_REPO:-$nvidia_utils_repo_default}" ;;
        *) die "unknown repo name: $repo_name" ;;
    esac
}

prepare_repo_checkout() {
    local repo_name="$1"
    local repo_url="$2"
    local checkout_dir="$3"
    rm -rf "$checkout_dir"
    git clone --quiet "$repo_url" "$checkout_dir"
}

choose_source_repo() {
    local version="$1"
    local repo_url match

    repo_url="$(resolve_repo_url nvidia-utils)"
    checkout_dir="$(mktemp -d)"
    if ! prepare_repo_checkout nvidia-utils "$repo_url" "$checkout_dir"; then
        rm -rf -- "$checkout_dir"
        checkout_dir=''
        die "failed to clone upstream Manjaro nvidia-utils repo from $repo_url"
    fi
    if [[ ! -d "$checkout_dir/.git" ]]; then
        rm -rf -- "$checkout_dir"
        checkout_dir=''
        die "failed to clone upstream Manjaro nvidia-utils repo from $repo_url"
    fi
    match="$(find_matching_commit "$checkout_dir" "$version" || true)"
    if [[ -n "$match" ]]; then
        printf '%s\n' "nvidia-utils|$repo_url|$match|$checkout_dir"
        return
    fi

    rm -rf "$checkout_dir"
    checkout_dir=''
    die "no upstream Manjaro nvidia-utils package repo contains target version $version"
}

stage_tree() {
    local checkout_dir="$1"
    local commit="$2"
    local stage_dir="$3"

    mkdir -p "$stage_dir"
    git -C "$checkout_dir" checkout -q "$commit"
    rsync -a --exclude '.git' "$checkout_dir/" "$stage_dir/"

    rewrite_stage_pkgbuild_for_open_dkms "$stage_dir/PKGBUILD"

    rm -rf -- "$stage_dir/patches"
    rsync -a "$repo_root/patches" "$stage_dir/"
}

run_makepkg() {
    local stage_dir="$1"
    local -a makepkg_args artifacts
    local arg require_artifacts=1
    shift

    for arg in "$@"; do
        case "$arg" in
            --packagelist|--printsrcinfo|--verifysource|-g|--geninteg|-o|--nobuild)
                require_artifacts=0
                ;;
            --source|--allsource)
                die 'source package modes are not supported by this wrapper'
                ;;
            -*)
                if [[ "$arg" == *S* ]]; then
                    die 'source package modes are not supported by this wrapper'
                fi
                ;;
        esac
    done

    (
        cd "$stage_dir"
        export AORUS_REPO_ROOT="$stage_dir"
        makepkg_args=(-Cfs --noconfirm)
        makepkg "${makepkg_args[@]}" "$@"

        if [[ "$require_artifacts" -eq 0 ]]; then
            return 0
        fi

        shopt -s nullglob
        artifacts=(nvidia-open-dkms-*.pkg.tar.*)
        if ((${#artifacts[@]} == 0)); then
            printf 'expected nvidia-open-dkms artifact in %s\n' "$stage_dir" >&2
            return 1
        fi
        mv -- "${artifacts[@]}" "$repo_root/"
    )
}

main() {
    local version selected repo_name repo_url commit
    version="$(detect_target_version)"
    selected="$(choose_source_repo "$version")"
    IFS='|' read -r repo_name repo_url commit checkout_dir <<<"$selected"

    case "${1-}" in
        --print-source-repo)
            printf '%s\n' "$repo_name"
            ;;
        --stage-only)
            [[ $# -eq 2 ]] || die '--stage-only requires a destination directory'
            stage_dir="$2"
            preserve_stage_dir=1
            prepare_stage_dir "$stage_dir"
            stage_tree "$checkout_dir" "$commit" "$stage_dir"
            ;;
        *)
            stage_dir="$(mktemp -d)"
            stage_tree "$checkout_dir" "$commit" "$stage_dir"
            run_makepkg "$stage_dir" "$@"
            ;;
    esac
}

main "$@"
