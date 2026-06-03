#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${REPO_ROOT}/lib/install-common.sh"

MKINITCPIO_DIRTY=0
GRUB_DIRTY=0
REBOOT_REQUIRED=0

parse_shell_string_value() {
  local expression="$1"
  local parsed

  eval "parsed=${expression}"
  printf '%s\n' "$parsed"
}

detect_bridge() {
  local stderr_file output status stderr_text
  stderr_file="$(mktemp)"

  set +e
  output="$("$AORUS_BRIDGE_BIN" detect 2>"$stderr_file")"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    rm -f -- "$stderr_file"
    printf '%s\n' "$output"
    return 0
  fi

  stderr_text="$(<"$stderr_file")"
  rm -f -- "$stderr_file"

  if [[ -n "$stderr_text" ]]; then
    printf '%s\n' "$stderr_text" >&2
    return 2
  fi

  return 1
}

extract_existing_bridge() {
  local file="$1"

  grep -oE 'pci=resource_alignment=35@[[:xdigit:]:.]+' "$file" | head -n1 | cut -d@ -f2 || true
}

resolve_bridge() {
  local detected
  local existing
  local status

  if detected="$(detect_bridge)"; then
    printf '%s\n' "$detected"
    return 0
  else
    status=$?
  fi

  if [[ "$status" -ne 1 ]]; then
    return "$status"
  fi

  existing="$(extract_existing_bridge "$GRUB_DEFAULT_PATH")"
  if [[ -n "$existing" ]]; then
    printf '%s\n' "$existing"
    return 0
  fi

  die 'could not determine bridge BDF for pci=resource_alignment=35@<bridge>'
}

rewrite_mkinitcpio() {
  local tmp_file line modules_str filtered_modules
  tmp_file="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^MODULES=\((.+)\)$ ]]; then
      # Strip MODULES=( and )
      modules_str="${BASH_REMATCH[1]}"
      # Just in case the module names have single quotes
      modules_str="${modules_str//\'/}"
      # Split into array (handles quoted and unquoted tokens)
      local -a modules=($modules_str)
      # Filter out NVIDIA modules
      filtered_modules=()
      for token in "${modules[@]}"; do
        case "$token" in
        nvidia | nvidia_drm | nvidia_modeset | nvidia_uvm) ;;
        *) filtered_modules+=("$token") ;;
        esac
      done
      # Join with spaces and write
      printf 'MODULES=(%s)\n' "${filtered_modules[*]}" >>"$tmp_file"
    else
      printf '%s\n' "$line" >>"$tmp_file"
    fi
  done <"$MKINITCPIO_CONF_PATH"
  if write_if_changed "$MKINITCPIO_CONF_PATH" "$tmp_file"; then
    MKINITCPIO_DIRTY=1
  fi
}

rewrite_modprobe_file() {
  local file="$1"
  local tmp_file line changed=0
  tmp_file="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == '# aorus-disabled:'* || "$line" == '#'* ]]; then
      printf '%s\n' "$line" >>"$tmp_file"
      continue
    fi

    if [[ "$line" == *nvidia* ]]; then
      printf '# aorus-disabled: %s\n' "$line" >>"$tmp_file"
      changed=1
      continue
    fi

    printf '%s\n' "$line" >>"$tmp_file"
  done <"$file"

  if [[ "$changed" -eq 1 ]] && write_if_changed "$file" "$tmp_file"; then
    MKINITCPIO_DIRTY=1
  else
    rm -f -- "$tmp_file"
  fi
}

rewrite_modprobe_tree() {
  local file
  local status

  ensure_directory "$MODPROBE_DIR"
  for file in "$MODPROBE_DIR"/*.conf; do
    [[ -e "$file" ]] || continue
    [[ "$file" == "$MODPROBE_DIR/aorus.conf" ]] && continue
    rewrite_modprobe_file "$file"
  done

  if install_repo_file "${HOST_FILES_DIR}/etc/modprobe.d/aorus.conf" "${MODPROBE_DIR}/aorus.conf" 0644; then
    MKINITCPIO_DIRTY=1
  else
    status=$?
    [[ "$status" -eq "$INSTALL_REPO_FILE_UNCHANGED" ]] || return "$status"
  fi
}

canonicalize_cmdline() {
  local bridge="$1"
  local value_expression="$2"
  local token
  local filtered=()
  local tokens=()
  local required=(
    "iommu=off"
    "intel_iommu=off"
    "thunderbolt.host_reset=false"
    "pcie_aspm.policy=performance"
    "thunderbolt.clx=0"
    "pcie_port_pm=off"
    "pci=resource_alignment=35@${bridge}"
  )

  if [[ -n "$value_expression" ]]; then
    local value
    value="$(parse_shell_string_value "$value_expression")"
    eval "tokens=( ${value} )"
  fi

  for token in "${tokens[@]}"; do
    case "$token" in
    *nvidia* | rd.driver.blacklist=*nvidia* | modprobe.blacklist=*nvidia* | module_blacklist=*nvidia* | iommu=* | intel_iommu=* | thunderbolt.host_reset=* | pcie_aspm.policy=* | thunderbolt.clx=* | pcie_port_pm=* | pci=resource_alignment=35@*)
      ;;
    *)
      filtered+=("$token")
      ;;
    esac
  done

  filtered+=("${required[@]}")
  printf '%s\n' "${filtered[*]}"
}

rewrite_grub() {
  local bridge="$1"
  local tmp_file line key value new_value changed=0
  local saw_default=0
  local saw_linux=0
  tmp_file="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
    GRUB_CMDLINE_LINUX_DEFAULT=*)
      saw_default=1
      key='GRUB_CMDLINE_LINUX_DEFAULT'
      value="${line#${key}=}"
      new_value="$(canonicalize_cmdline "$bridge" "$value")"
      printf '%s="%s"\n' "$key" "$new_value" >>"$tmp_file"
      [[ "$new_value" == "$(parse_shell_string_value "$value")" ]] || changed=1
      ;;
    GRUB_CMDLINE_LINUX=*)
      saw_linux=1
      key='GRUB_CMDLINE_LINUX'
      value="${line#${key}=}"
      new_value="$(canonicalize_cmdline "$bridge" "$value")"
      printf '%s="%s"\n' "$key" "$new_value" >>"$tmp_file"
      [[ "$new_value" == "$(parse_shell_string_value "$value")" ]] || changed=1
      ;;
    *)
      printf '%s\n' "$line" >>"$tmp_file"
      ;;
    esac
  done <"$GRUB_DEFAULT_PATH"

  if [[ "$saw_linux" -eq 0 ]]; then
    printf 'GRUB_CMDLINE_LINUX="%s"\n' "$(canonicalize_cmdline "$bridge" "''")" >>"$tmp_file"
    changed=1
  fi

  if [[ "$saw_default" -eq 0 ]]; then
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$(canonicalize_cmdline "$bridge" "''")" >>"$tmp_file"
    changed=1
  fi

  if [[ "$changed" -eq 1 ]] && write_if_changed "$GRUB_DEFAULT_PATH" "$tmp_file"; then
    GRUB_DIRTY=1
  else
    rm -f -- "$tmp_file"
  fi
}

install_binaries() {
  local status

  if install_repo_file "${REPO_ROOT}/aorus-bridge" "${USR_LOCAL_BIN_DIR}/aorus-bridge" 0755; then
    :
  else
    status=$?
    [[ "$status" -eq "$INSTALL_REPO_FILE_UNCHANGED" ]] || return "$status"
  fi

  if install_repo_file "${REPO_ROOT}/aorus-modules" "${USR_LOCAL_BIN_DIR}/aorus-modules" 0755; then
    :
  else
    status=$?
    [[ "$status" -eq "$INSTALL_REPO_FILE_UNCHANGED" ]] || return "$status"
  fi
}

install_host_files() {
  local status

  if install_repo_file "${HOST_FILES_DIR}/etc/udev/rules.d/80-aorus-disable-egpu-audio.rules" "${UDEV_RULES_DIR}/80-aorus-disable-egpu-audio.rules" 0644; then
    :
  else
    status=$?
    [[ "$status" -eq "$INSTALL_REPO_FILE_UNCHANGED" ]] || return "$status"
  fi

  if install_repo_file "${HOST_FILES_DIR}/etc/systemd/system/aorus.service" "${SYSTEMD_ROOT}/aorus.service" 0644; then
    :
  else
    status=$?
    [[ "$status" -eq "$INSTALL_REPO_FILE_UNCHANGED" ]] || return "$status"
  fi

  if install_repo_file "${HOST_FILES_DIR}/etc/systemd/system/nvidia-persistenced.service.d/aorus.conf" "${SYSTEMD_ROOT}/nvidia-persistenced.service.d/aorus.conf" 0644; then
    :
  else
    status=$?
    [[ "$status" -eq "$INSTALL_REPO_FILE_UNCHANGED" ]] || return "$status"
  fi
}

reload_daemons() {
  run_action 'reloading udev rules' "$UDEVADM_BIN" control --reload-rules
  run_action 'triggering NVIDIA PCI add uevents' "$UDEVADM_BIN" trigger --subsystem-match=pci --attr-match=vendor=0x10de --attr-match=device=0x22e8 --action=add || true
  run_action 'reloading systemd manager' "$SYSTEMCTL_BIN" daemon-reload
  run_action 'enabling aorus.service' "$SYSTEMCTL_BIN" enable aorus.service
}

main() {
  local bridge
  local status

  parse_common_args "$@"

  require_root 'install.sh'
  require_tool "$MKINITCPIO_BIN" 'mkinitcpio'
  require_tool "$GRUB_MKCONFIG_BIN" 'grub-mkconfig'
  require_tool "$INSTALL_BIN" 'install'
  require_tool "$SYSTEMCTL_BIN" 'systemctl'
  require_tool "$UDEVADM_BIN" 'udevadm'
  [[ -x "$AORUS_BRIDGE_BIN" ]] || die "missing helper: ${AORUS_BRIDGE_BIN}"
  [[ -x "${REPO_ROOT}/aorus-modules" ]] || die "missing helper: ${REPO_ROOT}/aorus-modules"

  if bridge="$(resolve_bridge)"; then
    :
  else
    status=$?
    exit "$status"
  fi

  rewrite_mkinitcpio
  rewrite_modprobe_tree
  rewrite_grub "$bridge"
  install_binaries
  install_host_files
  regenerate_if_dirty
  reload_daemons

  if [[ "$REBOOT_REQUIRED" -eq 1 ]]; then
    printf 'install complete; reboot required\n'
  else
    printf 'install complete; no reboot required\n'
  fi
}

main "$@"
