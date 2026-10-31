#!/usr/bin/env bash
# Launch the measured guest under SEV-SNP. Takes no arguments.
#
# launch-genesis and launch-target call this. Each one sets ZNS_STATE_IMG and
# ZEBRA_STATE_IMG to the host disk images before the call. launch-genesis takes
# those paths from the operator. launch-target sets them to its own disks under
# the hops directory. The state disks are not part of the measurement.
#
# ZNS_9P is optional: tag|hostpath|ro-or-rw entries separated by semicolons.
# ZNS_MINT_FWD and ZNS_ZEBRA_FWD are the host ports (guest ports stay 9465 and
# 9998). ZNS_QEMU_NAME is the QEMU -name. None of those are measurement inputs.
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

MINT_FWD="${ZNS_MINT_FWD:-9465}"
ZEBRA_FWD="${ZNS_ZEBRA_FWD:-9999}"
QEMU_NAME="${ZNS_QEMU_NAME:-zns-guest}"
# zns-migrate creates channel files as mode 0600. A writable export is served
# by virtfs-proxy-helper as the operator, so the standby account can read
# those files. The socket stays in a root-only directory.
proxy_helper_bin() {
  local candidate
  for candidate in \
    /usr/lib/qemu/virtfs-proxy-helper \
    /usr/lib/x86_64-linux-gnu/qemu/virtfs-proxy-helper \
    /usr/libexec/virtfs-proxy-helper
  do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  if command -v virtfs-proxy-helper >/dev/null 2>&1; then
    command -v virtfs-proxy-helper
    return
  fi
  echo "missing virtfs-proxy-helper from qemu-system-common" >&2
  exit 1
}

helper_pids=()
cleanup_helpers() {
  local pid
  if ((${#helper_pids[@]})); then
    for pid in "${helper_pids[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
  fi
}
trap cleanup_helpers EXIT INT TERM HUP

ninep_args=()
if [[ -n "${ZNS_9P:-}" ]]; then
  IFS=';' read -r -a specs <<<"${ZNS_9P}"
  i=0
  for spec in "${specs[@]}"; do
    [[ -n "$spec" ]] || continue
    IFS='|' read -r tag path mode <<<"$spec"
    if [[ -z "$tag" || -z "$path" || ! -d "$path" ]]; then
      echo "bad 9p mount: ${spec}" >&2
      exit 1
    fi
    if [[ "$mode" == "ro" ]]; then
      opt="local,id=fs${i},path=${path},security_model=none,readonly=on"
    elif [[ "$mode" != "rw" ]]; then
      echo "9p mode must be ro or rw: ${spec}" >&2
      exit 1
    else
      fs_uid="${SUDO_UID:-}"
      fs_gid="${SUDO_GID:-}"
      if [[ -z "$fs_uid" || "$fs_uid" == "0" ]]; then
        fs_uid="$(stat -c %u "$path")"
        fs_gid="$(stat -c %g "$path")"
      fi
      if [[ -z "$fs_uid" || "$fs_uid" == "0" ]]; then
        echo "$path is owned by root; the operator account has to own a writable 9p export" >&2
        exit 1
      fi
      mkdir -p /run/zns-9p
      chmod 700 /run/zns-9p
      sock="/run/zns-9p/$$-${i}.sock"
      rm -f "$sock"
      helper="$(proxy_helper_bin)" || exit 1
      "$helper" -n -u "$fs_uid" -g "$fs_gid" -p "$path" -S "$sock" \
        >>/run/zns-9p/helper.log 2>&1 &
      helper_pids+=("$!")
      ready=0
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if [[ -S "$sock" ]]; then
          ready=1
          break
        fi
        sleep 0.1
      done
      if [[ "$ready" -ne 1 ]]; then
        echo "virtfs-proxy-helper did not open $sock" >&2
        exit 1
      fi
      chmod 600 "$sock"
      opt="proxy,id=fs${i},socket=${sock},writeout=immediate"
    fi
    ninep_args+=(-fsdev "$opt" -device "virtio-9p-pci,fsdev=fs${i},mount_tag=${tag}")
    i=$((i + 1))
  done
fi

# zns-forward listens on the guest's external ports. Grafana on this host
# scrapes mint at 127.0.0.1:${MINT_FWD}/metrics and Zebra at
# 127.0.0.1:${ZEBRA_FWD}/metrics. These forwards are not part of the measurement.
# qemu stays in the foreground so the serial console keeps this tty. The
# proxy helpers are stopped when it exits.
qemu-system-x86_64 \
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
  ${ninep_args+"${ninep_args[@]}"} \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${MINT_FWD}-:9465,hostfwd=tcp:127.0.0.1:${ZEBRA_FWD}-:9998" \
  -device virtio-net-pci,netdev=net0 \
  -name "$QEMU_NAME" -nographic \
  -no-reboot
