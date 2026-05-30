#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo_root}/aorus-modules"

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

write_fake_modprobe() {
    local path="$1"
    local log_file="$2"

    cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_MODPROBE_LOG:?}"
EOF

    chmod +x "$path"
}

run_script_capture() {
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

test_default_invocation_loads_nvidia_then_uvm() {
    local tmpdir stdout_file stderr_file fake_modprobe log_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    fake_modprobe="${tmpdir}/modprobe"
    log_file="${tmpdir}/modprobe.log"
    : >"$log_file"
    write_fake_modprobe "$fake_modprobe" "$log_file"

    if ! run_script_capture "$stdout_file" "$stderr_file" \
        env MODPROBE_BIN="$fake_modprobe" FAKE_MODPROBE_LOG="$log_file" \
        bash "$script"; then
        printf 'expected default invocation to succeed\n' >&2
        return 1
    fi

    assert_equals $'--ignore-install nvidia\n--ignore-install nvidia_uvm' "$(<"$log_file")" \
        'default invocation should load nvidia first and nvidia_uvm second'
}

test_explicit_load_invocation_uses_same_sequence() {
    local tmpdir stdout_file stderr_file fake_modprobe log_file
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    fake_modprobe="${tmpdir}/modprobe"
    log_file="${tmpdir}/modprobe.log"
    : >"$log_file"
    write_fake_modprobe "$fake_modprobe" "$log_file"

    if ! run_script_capture "$stdout_file" "$stderr_file" \
        env MODPROBE_BIN="$fake_modprobe" FAKE_MODPROBE_LOG="$log_file" \
        bash "$script" load; then
        printf 'expected explicit load invocation to succeed\n' >&2
        return 1
    fi

    assert_equals $'--ignore-install nvidia\n--ignore-install nvidia_uvm' "$(<"$log_file")" \
        'load subcommand should use the same sequence as the default invocation'
}

test_unknown_subcommand_fails_with_usage() {
    local tmpdir stdout_file stderr_file status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"

    if run_script_capture "$stdout_file" "$stderr_file" bash "$script" nope; then
        printf 'expected unknown subcommand to fail\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals '2' "$status" 'unknown subcommand should exit 2'
    assert_contains 'usage: aorus-modules [load]' "$stderr_file"
}

main() {
    test_default_invocation_loads_nvidia_then_uvm
    test_explicit_load_invocation_uses_same_sequence
    test_unknown_subcommand_fails_with_usage
}

main "$@"
