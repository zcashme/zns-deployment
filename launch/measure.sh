#!/usr/bin/env bash
# Compute the expected SNP measurement and write build/snp-measurement.txt.
# CI runs this after build-image.sh. It does not start a VM.
set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

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
