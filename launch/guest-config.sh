# shellcheck shell=bash
# Shared launch settings and checks. Sourced by measure-guest.sh, print-guest-config.sh, and launch-guest.sh.
#
# Only these values go to sev-snp-measure in measure-guest.sh: vCPU count, CPU family,
# model and stepping, guest features, OVMF, kernel, initrd, and command line.
# Guest policy, KERNEL_HASHES, machine type, memory, CBITPOS, REDUCED_PHYS_BITS, and
# the -cpu setting are checked or printed here but are not passed to the tool. The
# policy is reported beside the digest instead. State disk paths, host forwards,
# and 9p directory mounts affect only launch.
# All three scripts read this file so the measurement and the launch use the same values.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KERNEL="${KERNEL:-$ROOT/build/vmlinuz}"
INITRD="${INITRD:-$ROOT/build/zns-initrd.img}"
# rdinit makes /scripts/init-premount/zns PID 1.
CMDLINE="${CMDLINE:-console=ttyS0 rdinit=/scripts/init-premount/zns}"
# build-image.sh writes this from ovmf_fd_sha256.
OVMF="${OVMF:-$ROOT/build/OVMF.amdsev.fd}"
# The testnet command omits policy=. QEMU's default is 0x30000.
GUEST_POLICY="${GUEST_POLICY:-0x30000}"
KERNEL_HASHES="${KERNEL_HASHES:-on}"
# SNPActive. The launch command does not set debug-swap, so that bit stays clear.
GUEST_FEATURES="${GUEST_FEATURES:-0x1}"
MACHINE="${MACHINE:-q35}"
# AMD EPYC 8024P. CPUID family 25, model 160, stepping 2, signature 0xaa0f02.
# QEMU has no named model for that CPUID. EPYC-Genoa is family 25, model 17, stepping 0.
# -cpu host is what yields this signature on the testnet machine.
# launch checks /proc/cpuinfo and exits unless it matches.
# sev-snp-measure: --vcpu-family 25 --vcpu-model 160 --vcpu-stepping 2
CPU="${CPU:-host}"
CPU_FAMILY="${CPU_FAMILY:-25}"
CPU_MODEL="${CPU_MODEL:-160}"
CPU_STEPPING="${CPU_STEPPING:-2}"
VCPUS="${VCPUS:-8}"
MEM="${MEM:-8G}"
CBITPOS="${CBITPOS:-51}"
REDUCED_PHYS_BITS="${REDUCED_PHYS_BITS:-1}"

ZNS_STATE_IMG="${ZNS_STATE_IMG:-}"
ZEBRA_STATE_IMG="${ZEBRA_STATE_IMG:-}"

MISSING=0
pin_value() {
  local key="$1" line val
  line="$(grep -E "^${key}[[:space:]]*=" "$ROOT/versions.toml" | head -n 1 || true)"
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  val="${val#\"}"
  val="${val%\"}"
  printf '%s' "$val"
}

check_ovmf() {
  local expected got
  expected="$(pin_value ovmf_fd_sha256)"
  if [[ -z "$expected" ]]; then
    echo "ovmf_fd_sha256 is empty" >&2
    exit 1
  fi
  got="$(python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$OVMF")"
  if [[ "$got" != "$expected" ]]; then
    echo "OVMF sha256 ${got} != ${expected}" >&2
    exit 1
  fi
}

check_kernel() {
  local expected got
  expected="$(pin_value kernel_vmlinuz_sha256)"
  if [[ -z "$expected" ]]; then
    echo "kernel_vmlinuz_sha256 is empty" >&2
    exit 1
  fi
  got="$(python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$KERNEL")"
  if [[ "$got" != "$expected" ]]; then
    echo "vmlinuz sha256 ${got} != ${expected}" >&2
    exit 1
  fi
}

require_measured() {
  local name="$1" value="$2"
  if [[ -z "$value" || "$value" == "TODO" ]]; then
    echo "launch parameter ${name} is not pinned" >&2
    # Read by the script that sourced this file.
    # shellcheck disable=SC2034
    MISSING=1
  fi
}
