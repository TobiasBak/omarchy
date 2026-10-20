#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

windows_vm_command="$ROOT/bin/omarchy-windows-vm"

rg -q '^    restart: "no"$' "$windows_vm_command" ||
  fail "Windows VM uses manual startup by default"
pass "Windows VM uses manual startup by default"

if rg -q '^    restart: unless-stopped$' "$windows_vm_command"; then
  fail "Windows VM does not restart automatically at boot"
fi
pass "Windows VM does not restart automatically at boot"

# Tolerate either shell quoting of the argument.
rg -q 'title:"?Windows VM - Omarchy"' "$windows_vm_command" ||
  fail "Windows VM launches FreeRDP with its expected title"
pass "Windows VM launches FreeRDP with its expected title"

# Exercise public preparation with owned scratch and fake mount/socket state.
# Real bind restoration and root caller checks live in the two namespace suites.
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export HOME="$test_tmp/home" OMARCHY_WINDOWS_DIR="$test_tmp/runtime"
mkdir -p "$HOME" "$OMARCHY_WINDOWS_DIR"
omarchy-hw-x86() { :; }
set -- help
source "$windows_vm_command" >"$test_tmp/help"
grep -q '^  prepare ' "$test_tmp/help" || fail "help does not advertise prepare"

# Deny every container/guest boundary, including inspection of a running VM.
call_log="$test_tmp/calls"
: >"$call_log"
docker() { printf 'docker %s\n' "$*" >>"$call_log"; printf 'running\n'; }
docker-compose() { printf 'compose %s\n' "$*" >>"$call_log"; }
xfreerdp3() { printf 'rdp %s\n' "$*" >>"$call_log"; }
sleep() { printf 'sleep %s\n' "$*" >>"$call_log"; }

for args in 'help' '--help' '-h' 'prepare --help' 'prepare -h' 'bogus' 'prepar' 'prepare unsupported' '__priv prepare'; do
  read -ra argv <<<"$args"
  if (set -- "${argv[@]}"; source "$windows_vm_command") >"$test_tmp/output" 2>&1; then
    case "$args" in
    bogus | prepar | 'prepare unsupported' | '__priv prepare') fail "invalid operation succeeded: $args" ;;
    esac
  else
    case "$args" in
    bogus | prepar | 'prepare unsupported' | '__priv prepare') ;;
    *) fail "help failed: $args" ;;
    esac
  fi
done
[[ ! -s $call_log && ! -e $COMPOSE_FILE ]] || fail "discovery/invalid dispatch touched the VM"
pass "help advertises prepare without allocation and invalid dispatch fails loudly"

resolve_caller
cat >"$COMPOSE_FILE" <<EOF
services:
  windows:
    environment:
      PROTECT: "Y"
    volumes:
      - $EXPECTED_STORAGE:/storage
      - $EXPECTED_SHARED:/shared
EOF
chmod 0640 "$COMPOSE_FILE"
VM_LOCK_DIR="$test_tmp/lock"
mkdir "$VM_LOCK_DIR"
# Simulate only the root-owned lock's uid. All other file trust checks, flock,
# action selection and compose validation remain real.
stat() {
  if [[ $* == '-Lc %u '* && ${!#} == "$VM_LOCK_DIR" ]]; then
    printf '0\n'
  else
    command stat "$@"
  fi
}
mount_state=ready
mounts_ready() { [[ $mount_state == ready ]]; }
needs_sudo=0
omarchy-sudo-docker() { ((needs_sudo)); }
# Target selection itself is security-tested by the compose suite. This fake
# represents its validated output; pkexec never executes anything in this test.
priv_target() { printf '/trusted/omarchy-windows-vm\n'; }
elevation_rc=0
pkexec() { printf 'pkexec %s\n' "$*" >>"$call_log"; return "$elevation_rc"; }

compose_before=$(sha256sum "$COMPOSE_FILE")
prepare_windows || fail "ready docker-group preparation failed"
prepare_windows || fail "repeated ready preparation failed"
[[ ! -s $call_log && $(sha256sum "$COMPOSE_FILE") == "$compose_before" ]] || fail "ready preparation mutated config or invoked a VM command"
flock -n "$VM_LOCK_DIR" true || fail "successful preparation retained the lifecycle lock"
pass "ready docker-group preparation is idempotent and releases the lifecycle lock"

mount_state=missing
prepare_windows || fail "docker-group restoration did not request elevation"
[[ $(<"$call_log") == 'pkexec /trusted/omarchy-windows-vm __priv prepare' ]] || fail "restoration did not elevate the exact prepare operation"
: >"$call_log"
mount_state=ready
sed -i '/PROTECT: "Y"/d' "$COMPOSE_FILE"
prepare_windows || fail "docker-group security migration did not request elevation"
[[ $(<"$call_log") == 'pkexec /trusted/omarchy-windows-vm __priv prepare' ]] || fail "security migration bypassed trusted preparation"
sed -i '/environment:/a\      PROTECT: "Y"' "$COMPOSE_FILE"
: >"$call_log"
needs_sudo=1
prepare_windows || fail "non-docker preparation did not request elevation"
[[ $(<"$call_log") == 'pkexec /trusted/omarchy-windows-vm __priv prepare' ]] || fail "non-docker preparation did not use trusted escalation"
: >"$call_log"
elevation_rc=42
if prepare_windows; then fail "authorization failure was hidden"; else rc=$?; fi
((rc == 42)) || fail "authorization failure status was lost"
[[ $(<"$call_log") == 'pkexec /trusted/omarchy-windows-vm __priv prepare' ]] || fail "authorization failure fell back to VM startup"
: >"$call_log"
priv_target() { return 1; }
prepare_windows >"$test_tmp/output" 2>&1 && fail "untrusted escalation target was accepted"
[[ ! -s $call_log ]] || fail "untrusted target reached pkexec or Docker"
pass "preparation elevates for restoration and propagates authorization/trust failures without startup"

needs_sudo=0
chmod 0666 "$COMPOSE_FILE"
prepare_windows >"$test_tmp/output" 2>&1 && fail "preparation accepted a writable compose"
flock -n "$VM_LOCK_DIR" true || fail "failed preparation retained the lifecycle lock"
chmod 0640 "$COMPOSE_FILE"
sed -i 's|:/shared|:/storage|' "$COMPOSE_FILE"
prepare_windows >"$test_tmp/output" 2>&1 && fail "preparation accepted duplicate/missing mounts"
[[ ! -s $call_log ]] || fail "invalid preparation touched the VM"
pass "preparation rejects unsafe config, releases its lock on failure, and never touches the VM"
