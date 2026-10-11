#!/usr/bin/env bash
# Launch the measured guest under SEV-SNP. Takes no arguments.
#
# Needs ZNS_STATE_IMG and ZEBRA_STATE_IMG set to the host disk images.
# The state disks are not part of the measurement.
set -euo pipefail

# shellcheck source=guest-config.sh
source "$(dirname "${BASH_SOURCE[0]}")/guest-config.sh"

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

if [[ $# -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi

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
