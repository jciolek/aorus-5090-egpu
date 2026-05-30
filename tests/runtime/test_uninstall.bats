#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo_root}/uninstall.sh"

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

    grep -Fq -- "$needle" "$file" || {
        printf 'expected to find %s in %s\n' "$needle" "$file" >&2
        return 1
    }
}

assert_file_exists() {
    local path="$1"

    [[ -e "$path" ]] || {
        printf 'expected file to exist: %s\n' "$path" >&2
        return 1
    }
}

assert_not_exists() {
    local path="$1"

    [[ ! -e "$path" ]] || {
        printf 'expected file to be absent: %s\n' "$path" >&2
        return 1
    }
}

assert_file_content() {
    local expected="$1"
    local file="$2"
    local actual

    actual="$(<"$file")"
    [[ "$expected" == "$actual" ]] || {
        printf 'unexpected contents for %s\nexpected:\n%s\nactual:\n%s\n' "$file" "$expected" "$actual" >&2
        return 1
    }
}

write_fake_command() {
    local path="$1"
    local log_file="$2"
    local body="$3"
    local command_name

    command_name="$(basename "$path")"

    cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$command_name" "\$*" >>"$log_file"
$body
EOF
    chmod +x "$path"
}

write_fake_bridge_helper() {
    local path="$1"
    local log_file="$2"

    cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'aorus-bridge %s\n' "\$*" >>"$log_file"
exit 0
EOF
    chmod +x "$path"
}

run_uninstall() {
    local root="$1"

    env \
        AORUS_SETUP_ALLOW_NON_ROOT=1 \
        PATH="${root}/bin:${PATH}" \
        ETC_ROOT="${root}/etc" \
        MODPROBE_DIR="${root}/etc/modprobe.d" \
        UDEV_RULES_DIR="${root}/etc/udev/rules.d" \
        SYSTEMD_ROOT="${root}/etc/systemd/system" \
        USR_LOCAL_BIN_DIR="${root}/usr/local/bin" \
        MKINITCPIO_CONF_PATH="${root}/etc/mkinitcpio.conf" \
        GRUB_DEFAULT_PATH="${root}/etc/default/grub" \
        GRUB_CFG_PATH="${root}/boot/grub/grub.cfg" \
        bash "$script"
}

run_uninstall_capture() {
    local root="$1"
    local stdout_file="$2"
    local stderr_file="$3"

    if run_uninstall "$root" >"$stdout_file" 2>"$stderr_file"; then
        return 0
    fi
    return 1
}

prepare_fake_root() {
    local root="$1"
    local log_file="$2"

    mkdir -p "${root}/etc/modprobe.d" "${root}/etc/default" \
        "${root}/etc/udev/rules.d" "${root}/etc/systemd/system/nvidia-persistenced.service.d" \
        "${root}/usr/local/bin" "${root}/boot/grub" "${root}/bin"

    write_fake_command "${root}/bin/mkinitcpio" "$log_file" 'exit 0'
    write_fake_command "${root}/bin/grub-mkconfig" "$log_file" 'while [[ $# -gt 0 ]]; do if [[ "$1" == "-o" ]]; then shift; : >"$1"; fi; shift; done'
    write_fake_command "${root}/bin/modprobe" "$log_file" 'exit 0'
    write_fake_command "${root}/bin/systemctl" "$log_file" 'exit 0'
    write_fake_command "${root}/bin/udevadm" "$log_file" 'exit 0'
}

seed_installed_state() {
    local root="$1"

    cat >"${root}/etc/mkinitcpio.conf" <<'EOF'
MODULES=(xhci_pci thunderbolt)
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)
EOF
    cat >"${root}/etc/mkinitcpio.conf.aorus.00" <<'EOF'
MODULES=(legacy)
BINARIES=()
FILES=()
HOOKS=(base)
EOF
    cat >"${root}/etc/mkinitcpio.conf.aorus.02" <<'EOF'
MODULES=(restored newest)
BINARIES=()
FILES=()
HOOKS=(base fsck)
EOF

    cat >"${root}/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu=off intel_iommu=off thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
GRUB_CMDLINE_LINUX="iommu=off intel_iommu=off thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
EOF
    cat >"${root}/etc/default/grub.aorus.01" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="audit=1"
EOF

    cat >"${root}/etc/modprobe.d/existing.conf" <<'EOF'
# aorus-disabled: options nvidia NVreg_Foo=1
# aorus-disabled: softdep nvidia pre: something
options snd_hda_intel power_save=1
EOF
    cat >"${root}/etc/modprobe.d/existing.conf.aorus.00" <<'EOF'
options nvidia NVreg_Foo=1
softdep nvidia pre: something
options snd_hda_intel power_save=1
EOF
    cat >"${root}/etc/modprobe.d/deleted.conf.aorus.00" <<'EOF'
options nvidia NVreg_RegistryDwords=PerfLevelSrc=0x2222
EOF

    printf 'installed helper\n' >"${root}/usr/local/bin/aorus-bridge"
    printf 'installed helper\n' >"${root}/usr/local/bin/aorus-modules"
    printf 'installed rule\n' >"${root}/etc/udev/rules.d/80-aorus-disable-egpu-audio.rules"
    printf 'installed service\n' >"${root}/etc/systemd/system/aorus.service"
    printf 'installed dropin\n' >"${root}/etc/systemd/system/nvidia-persistenced.service.d/aorus.conf"
    printf 'installed blacklist\n' >"${root}/etc/modprobe.d/aorus.conf"
}

test_uninstall_attempts_runtime_rollback() {
    local tmpdir log_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    log_file="${tmpdir}/commands.log"
    : >"$log_file"

    prepare_fake_root "$tmpdir" "$log_file"
    seed_installed_state "$tmpdir"
    write_fake_bridge_helper "${tmpdir}/usr/local/bin/aorus-bridge" "$log_file"

    run_uninstall "$tmpdir"

    assert_contains 'aorus-bridge restore' "$log_file"
    assert_contains 'modprobe -r nvidia_uvm' "$log_file"
    assert_contains 'modprobe -r nvidia_drm' "$log_file"
    assert_contains 'modprobe -r nvidia_modeset' "$log_file"
    assert_contains 'modprobe -r nvidia' "$log_file"
}

test_uninstall_reports_reboot_required_when_boot_artifacts_regenerated() {
    local tmpdir log_file stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    log_file="${tmpdir}/commands.log"
    stdout_file="${tmpdir}/stdout.log"
    stderr_file="${tmpdir}/stderr.log"
    : >"$log_file"

    prepare_fake_root "$tmpdir" "$log_file"
    seed_installed_state "$tmpdir"
    write_fake_bridge_helper "${tmpdir}/usr/local/bin/aorus-bridge" "$log_file"

    if ! run_uninstall_capture "$tmpdir" "$stdout_file" "$stderr_file"; then
        printf 'expected uninstall.sh to succeed for managed state\n' >&2
        return 1
    fi

    assert_contains 'uninstall complete; reboot required' "$stdout_file"
}

test_uninstall_restores_backups_removes_owned_artifacts_and_reloads_daemons() {
    local tmpdir log_file count
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    log_file="${tmpdir}/commands.log"
    : >"$log_file"

    prepare_fake_root "$tmpdir" "$log_file"
    seed_installed_state "$tmpdir"

    run_uninstall "$tmpdir"

    assert_file_content "$(cat <<'EOF'
MODULES=(restored newest)
BINARIES=()
FILES=()
HOOKS=(base fsck)
EOF
)" "${tmpdir}/etc/mkinitcpio.conf"
    assert_file_content "$(cat <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="audit=1"
EOF
)" "${tmpdir}/etc/default/grub"
    assert_file_content "$(cat <<'EOF'
options nvidia NVreg_Foo=1
softdep nvidia pre: something
options snd_hda_intel power_save=1
EOF
)" "${tmpdir}/etc/modprobe.d/existing.conf"
    assert_file_content "$(cat <<'EOF'
options nvidia NVreg_RegistryDwords=PerfLevelSrc=0x2222
EOF
)" "${tmpdir}/etc/modprobe.d/deleted.conf"

    assert_not_exists "${tmpdir}/usr/local/bin/aorus-bridge"
    assert_not_exists "${tmpdir}/usr/local/bin/aorus-modules"
    assert_not_exists "${tmpdir}/etc/udev/rules.d/80-aorus-disable-egpu-audio.rules"
    assert_not_exists "${tmpdir}/etc/systemd/system/aorus.service"
    assert_not_exists "${tmpdir}/etc/systemd/system/nvidia-persistenced.service.d/aorus.conf"
    assert_not_exists "${tmpdir}/etc/modprobe.d/aorus.conf"

    assert_contains 'systemctl disable aorus.service' "$log_file"
    assert_contains 'systemctl daemon-reload' "$log_file"
    assert_contains 'udevadm control --reload-rules' "$log_file"
    assert_contains 'mkinitcpio -P' "$log_file"
    assert_contains 'grub-mkconfig -o ' "$log_file"
}

test_uninstall_ignores_unmanaged_mkinitcpio_and_grub_without_backups() {
    local tmpdir log_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    log_file="${tmpdir}/commands.log"
    : >"$log_file"

    prepare_fake_root "$tmpdir" "$log_file"
    cat >"${tmpdir}/etc/mkinitcpio.conf" <<'EOF'
MODULES=(xhci_pci thunderbolt)
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)
EOF
    cat >"${tmpdir}/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu=off"
GRUB_CMDLINE_LINUX="audit=1"
EOF

    run_uninstall "$tmpdir"
}

test_uninstall_fails_when_managed_modprobe_file_has_no_backup() {
    local tmpdir log_file stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    log_file="${tmpdir}/commands.log"
    stdout_file="${tmpdir}/stdout.log"
    stderr_file="${tmpdir}/stderr.log"
    : >"$log_file"

    prepare_fake_root "$tmpdir" "$log_file"
    cat >"${tmpdir}/etc/modprobe.d/existing.conf" <<'EOF'
# aorus-disabled: options nvidia NVreg_Foo=1
options snd_hda_intel power_save=1
EOF

    if run_uninstall_capture "$tmpdir" "$stdout_file" "$stderr_file"; then
        printf 'expected uninstall.sh to fail when a managed modprobe file has no backup\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals '1' "$status" 'uninstall should fail when no backup exists for managed modprobe files'
    assert_contains 'missing backup for managed file' "$stderr_file"
}

test_uninstall_fails_when_canonical_managed_grub_has_no_backup() {
    local tmpdir log_file stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    log_file="${tmpdir}/commands.log"
    stdout_file="${tmpdir}/stdout.log"
    stderr_file="${tmpdir}/stderr.log"
    : >"$log_file"

    prepare_fake_root "$tmpdir" "$log_file"
    cat >"${tmpdir}/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu=off intel_iommu=off thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
GRUB_CMDLINE_LINUX="iommu=off intel_iommu=off thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
EOF
    printf 'previous service backup\n' >"${tmpdir}/etc/systemd/system/aorus.service.aorus.00"

    if run_uninstall_capture "$tmpdir" "$stdout_file" "$stderr_file"; then
        printf 'expected uninstall.sh to fail when a canonical managed grub file has no backup\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals '1' "$status" 'uninstall should fail when no backup exists for managed grub files'
    assert_contains 'missing backup for managed file' "$stderr_file"
}

test_uninstall_fails_when_install_managed_mkinitcpio_has_no_backup() {
    local tmpdir log_file stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    log_file="${tmpdir}/commands.log"
    stdout_file="${tmpdir}/stdout.log"
    stderr_file="${tmpdir}/stderr.log"
    : >"$log_file"

    prepare_fake_root "$tmpdir" "$log_file"
    cat >"${tmpdir}/etc/mkinitcpio.conf" <<'EOF'
# preserved comment from existing config
MODULES=(amdgpu xhci_pci thunderbolt)
BINARIES=(/usr/bin/setfont)
FILES=()
HOOKS=(base systemd autodetect modconf block filesystems fsck)
# preserved tail comment
EOF
    printf 'previous helper backup\n' >"${tmpdir}/usr/local/bin/aorus-bridge.aorus.00"

    if run_uninstall_capture "$tmpdir" "$stdout_file" "$stderr_file"; then
        printf 'expected uninstall.sh to fail when an install-managed mkinitcpio file has no backup\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals '1' "$status" 'uninstall should fail when no backup exists for managed mkinitcpio files'
    assert_contains 'missing backup for managed file' "$stderr_file"
}

test_uninstall_reports_its_own_root_requirement() {
    local tmpdir log_file stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    log_file="${tmpdir}/commands.log"
    stdout_file="${tmpdir}/stdout.log"
    stderr_file="${tmpdir}/stderr.log"
    : >"$log_file"

    prepare_fake_root "$tmpdir" "$log_file"

    if env \
        PATH="${tmpdir}/bin:${PATH}" \
        ETC_ROOT="${tmpdir}/etc" \
        MODPROBE_DIR="${tmpdir}/etc/modprobe.d" \
        UDEV_RULES_DIR="${tmpdir}/etc/udev/rules.d" \
        SYSTEMD_ROOT="${tmpdir}/etc/systemd/system" \
        USR_LOCAL_BIN_DIR="${tmpdir}/usr/local/bin" \
        MKINITCPIO_CONF_PATH="${tmpdir}/etc/mkinitcpio.conf" \
        GRUB_DEFAULT_PATH="${tmpdir}/etc/default/grub" \
        GRUB_CFG_PATH="${tmpdir}/boot/grub/grub.cfg" \
        bash "$script" >"$stdout_file" 2>"$stderr_file"; then
        printf 'expected uninstall.sh to require root when override is absent\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals '1' "$status" 'uninstall should fail before running as non-root'
    assert_contains 'uninstall.sh must be run as root' "$stderr_file"
}

main() {
    test_uninstall_restores_backups_removes_owned_artifacts_and_reloads_daemons
    test_uninstall_attempts_runtime_rollback
    test_uninstall_reports_reboot_required_when_boot_artifacts_regenerated
    test_uninstall_ignores_unmanaged_mkinitcpio_and_grub_without_backups
    test_uninstall_fails_when_managed_modprobe_file_has_no_backup
    test_uninstall_fails_when_canonical_managed_grub_has_no_backup
    test_uninstall_fails_when_install_managed_mkinitcpio_has_no_backup
    test_uninstall_reports_its_own_root_requirement
}

main "$@"
