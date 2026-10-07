#!/usr/bin/env bash
# Canonical SEV-SNP launch.
#
# The expected measurement has to be computed from these same values:
#   kernel, initrd, cmdline, guest policy, kernel-hashes, CPU, vCPU count, OVMF.
# Host state disks are attached here and are not part of that measurement.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KERNEL="${KERNEL:-$ROOT/build/vmlinuz}"
INITRD="${INITRD:-$ROOT/build/zns-initrd.img}"
# This string is part of the measurement.
CMDLINE="${CMDLINE:-console=ttyS0}"
OVMF="${OVMF:-TODO}"
GUEST_POLICY="${GUEST_POLICY:-TODO}"
KERNEL_HASHES="${KERNEL_HASHES:-on}"
MACHINE="${MACHINE:-q35}"
# TODO: pin the production CPU, vCPU count, RAM, and SNP address bits.
CPU="${CPU:-TODO}"
VCPUS="${VCPUS:-TODO}"
MEM="${MEM:-TODO}"
CBITPOS="${CBITPOS:-TODO}"
REDUCED_PHYS_BITS="${REDUCED_PHYS_BITS:-TODO}"

# Runtime volumes. Recreating them does not change the measurement.
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
machine=${MACHINE}
cpu=${CPU}
vcpus=${VCPUS}
mem=${MEM}
cbitpos=${CBITPOS}
reduced_phys_bits=${REDUCED_PHYS_BITS}
zns_state_img=${ZNS_STATE_IMG}
zebra_state_img=${ZEBRA_STATE_IMG}
EOF
}

MISSING=0
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
  require_measured cpu "$CPU"
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

  # TODO: invoke the SNP measurement tool with the parameters printed below
  # and write a single hex line to build/snp-measurement.txt.
  # The QEMU launch in this file has to keep using those same values.
  echo "TODO: expected SNP measurement is not computed yet" >&2
  print_params >&2
  exit 1
}

launch() {
  require_measured kernel "$KERNEL"
  require_measured initrd "$INITRD"
  require_measured cmdline "$CMDLINE"
  require_measured ovmf "$OVMF"
  require_measured guest_policy "$GUEST_POLICY"
  require_measured cpu "$CPU"
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

  exec qemu-system-x86_64 \
    -enable-kvm \
    -cpu "$CPU" \
    -machine "${MACHINE},confidential-guest-support=sev0,memory-backend=ram0" \
    -object "memory-backend-memfd,id=ram0,size=${MEM},share=true" \
    -smp "$VCPUS" \
    -object "sev-snp-guest,id=sev0,cbitpos=${CBITPOS},reduced-phys-bits=${REDUCED_PHYS_BITS},policy=${GUEST_POLICY},kernel-hashes=${KERNEL_HASHES}" \
    -bios "$OVMF" \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "$CMDLINE" \
    -nographic \
    -serial mon:stdio \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -drive "file=${ZNS_STATE_IMG},if=none,id=zns-state,format=raw" \
    -device virtio-blk-pci,drive=zns-state \
    -drive "file=${ZEBRA_STATE_IMG},if=none,id=zebra-state,format=raw" \
    -device virtio-blk-pci,drive=zebra-state
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
