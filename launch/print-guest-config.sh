#!/usr/bin/env bash
# Print the launch settings as key=value lines.
# CI reads these for the release manifest and pack-upgrade reads guest_policy from them.
set -euo pipefail

# shellcheck source=guest-config.sh
source "$(dirname "${BASH_SOURCE[0]}")/guest-config.sh"

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
