#!/usr/bin/env bash
# SEV-SNP launch.
#
# Compute the expected measurement from these values:
#   kernel, initrd, cmdline, guest policy, kernel-hashes, CPU signature, vCPU count, OVMF.
# The state disks are not part of that measurement.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KERNEL="${KERNEL:-$ROOT/build/vmlinuz}"
INITRD="${INITRD:-$ROOT/build/zns-initrd.img}"
# rdinit makes /scripts/init-premount/zns-testnet PID 1.
CMDLINE="${CMDLINE:-console=ttyS0 rdinit=/scripts/init-premount/zns-testnet}"
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

print_params() {
  cat <<EOF
kernel=${KERNEL}
initrd=${INITRD}
cmdline=${CMDLINE}
ovmf=${OVMF}
guest_policy=${GUEST_POLICY}
kernel_hashes=${KERNEL_HASHES}
guest_features=${GUEST_FEATURES}
machine=${MACHINE}
cpu=${CPU}
cpu_family=${CPU_FAMILY}
cpu_model=${CPU_MODEL}
cpu_stepping=${CPU_STEPPING}
vcpus=${VCPUS}
mem=${MEM}
cbitpos=${CBITPOS}
reduced_phys_bits=${REDUCED_PHYS_BITS}
zns_state_img=${ZNS_STATE_IMG}
zebra_state_img=${ZEBRA_STATE_IMG}
EOF
}

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

cpuinfo_field() {
  local key="$1" line val
  line="$(grep -m1 -E "^${key}[[:space:]]*:" /proc/cpuinfo || true)"
  val="${line#*:}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

check_cpu() {
  local family model stepping
  if [[ ! -r /proc/cpuinfo ]]; then
    echo "CPU signature check needs /proc/cpuinfo" >&2
    exit 1
  fi
  family="$(cpuinfo_field 'cpu family')"
  model="$(cpuinfo_field 'model')"
  stepping="$(cpuinfo_field 'stepping')"
  if [[ "$family" != "$CPU_FAMILY" || "$model" != "$CPU_MODEL" || "$stepping" != "$CPU_STEPPING" ]]; then
    echo "CPU signature ${family:-?}/${model:-?}/${stepping:-?} != ${CPU_FAMILY}/${CPU_MODEL}/${CPU_STEPPING}" >&2
    exit 1
  fi
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
    MISSING=1
  fi
}

measure() {
  require_measured kernel "$KERNEL"
  require_measured initrd "$INITRD"
  require_measured cmdline "$CMDLINE"
  require_measured ovmf "$OVMF"
  require_measured guest_policy "$GUEST_POLICY"
  require_measured guest_features "$GUEST_FEATURES"
  require_measured cpu "$CPU"
  require_measured cpu_family "$CPU_FAMILY"
  require_measured cpu_model "$CPU_MODEL"
  require_measured cpu_stepping "$CPU_STEPPING"
  require_measured vcpus "$VCPUS"
  require_measured cbitpos "$CBITPOS"
  require_measured reduced_phys_bits "$REDUCED_PHYS_BITS"
  if [[ "$KERNEL_HASHES" != "on" ]]; then
    echo "kernel_hashes must be on" >&2
    MISSING=1
  fi
  if [[ "$MISSING" -ne 0 ]]; then
    exit 1
  fi
  if [[ ! -f "$KERNEL" || ! -f "$INITRD" || ! -f "$OVMF" ]]; then
    echo "kernel, initrd, and OVMF files must exist before measuring" >&2
    exit 1
  fi
  check_ovmf
  check_kernel

  local tool measurement out
  tool="$ROOT/build/snp-measure-venv/bin/sev-snp-measure"
  if [[ ! -x "$tool" ]]; then
    echo "sev-snp-measure is not installed; run launch/install-snp-measure.sh" >&2
    exit 1
  fi
  # Guest policy is reported beside this digest. The digest does not include it.
  measurement="$("$tool" \
    --mode snp \
    --vmm-type QEMU \
    --vcpus "$VCPUS" \
    --vcpu-family "$CPU_FAMILY" \
    --vcpu-model "$CPU_MODEL" \
    --vcpu-stepping "$CPU_STEPPING" \
    --guest-features "$GUEST_FEATURES" \
    --ovmf "$OVMF" \
    --kernel "$KERNEL" \
    --initrd "$INITRD" \
    --append "$CMDLINE")"
  if [[ ! "$measurement" =~ ^[0-9a-f]{96}$ ]]; then
    echo "sev-snp-measure returned ${measurement}" >&2
    exit 1
  fi
  out="$ROOT/build/snp-measurement.txt"
  printf '%s\n' "$measurement" >"$out"
  printf '%s\n' "$measurement"
}

launch() {
  require_measured kernel "$KERNEL"
  require_measured initrd "$INITRD"
  require_measured cmdline "$CMDLINE"
  require_measured ovmf "$OVMF"
  require_measured guest_policy "$GUEST_POLICY"
  require_measured guest_features "$GUEST_FEATURES"
  require_measured cpu "$CPU"
  require_measured cpu_family "$CPU_FAMILY"
  require_measured cpu_model "$CPU_MODEL"
  require_measured cpu_stepping "$CPU_STEPPING"
  require_measured vcpus "$VCPUS"
  require_measured mem "$MEM"
  require_measured cbitpos "$CBITPOS"
  require_measured reduced_phys_bits "$REDUCED_PHYS_BITS"
  if [[ "$KERNEL_HASHES" != "on" ]]; then
    echo "kernel_hashes must be on" >&2
    MISSING=1
  fi
  if [[ "$MISSING" -ne 0 ]]; then
    exit 1
  fi
  if [[ -z "$ZNS_STATE_IMG" || -z "$ZEBRA_STATE_IMG" ]]; then
    echo "set ZNS_STATE_IMG and ZEBRA_STATE_IMG to the host volume files" >&2
    exit 1
  fi
  if [[ ! -f "$KERNEL" || ! -f "$OVMF" ]]; then
    echo "kernel and OVMF files must exist before launching" >&2
    exit 1
  fi
  check_ovmf
  check_kernel
  check_cpu

  # zns-forward listens on the guest's external ports. Grafana on this host
  # scrapes mint at 127.0.0.1:9465/metrics and Zebra at 127.0.0.1:9999/metrics.
  # These forwards are not part of the measurement.
  exec qemu-system-x86_64 \
    -enable-kvm \
    -machine "${MACHINE},confidential-guest-support=sev0,vmport=off" \
    -cpu "$CPU" \
    -smp "$VCPUS" \
    -m "$MEM" \
    -object "sev-snp-guest,id=sev0,cbitpos=${CBITPOS},reduced-phys-bits=${REDUCED_PHYS_BITS},policy=${GUEST_POLICY},kernel-hashes=${KERNEL_HASHES}" \
    -bios "$OVMF" \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "$CMDLINE" \
    -drive "file=${ZNS_STATE_IMG},if=virtio,format=raw" \
    -drive "file=${ZEBRA_STATE_IMG},if=virtio,format=raw" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:9465-:9465,hostfwd=tcp:127.0.0.1:9999-:9998 \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    -no-reboot
}

case "${1:-}" in
--print)
  print_params
  ;;
--measure)
  measure
  ;;
"")
  launch
  ;;
*)
  echo "usage: $0 [--print|--measure]" >&2
  exit 2
  ;;
esac
