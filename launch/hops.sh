# Shared path and tag helpers for the launch commands.
#
# Each network has its own directory, $ZNS_HOPS/<network>/. current in that
# directory is the release tag of the guest that is live for that network.
# It is a name, not a counter. migrate writes the next tag only after
# receipt.bin appears, and it does not compare version numbers.
#
# ZNS_NETWORK is mainnet or testnet on every command. The directory records
# that name in network. Images, logs, snapshots, and the upgrade and
# transport directories for one network stay in that directory.

HOPS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# versions.toml networks, one per line.
versions_networks() {
  local line
  line="$(grep -E '^networks[[:space:]]*=' "$HOPS_REPO_ROOT/versions.toml" | head -n 1 || true)"
  if [[ -z "$line" ]]; then
    echo "versions.toml has no networks" >&2
    exit 1
  fi
  grep -oE '"[a-z]+"' <<<"${line#*=}" | tr -d '"'
}

require_network() {
  local net="${ZNS_NETWORK:-}"
  if [[ "$net" != "mainnet" && "$net" != "testnet" ]]; then
    echo "set ZNS_NETWORK=mainnet or ZNS_NETWORK=testnet" >&2
    return 1
  fi
  if ! versions_networks | grep -qxF -- "$net"; then
    echo "network ${net} is not in versions.toml networks" >&2
    return 1
  fi
  printf '%s\n' "$net"
}

# The parent directory. ZNS_HOPS selects another parent. The network
# directory is a child of this path.
hops_base() {
  if [[ -n "${ZNS_HOPS:-}" ]]; then
    printf '%s\n' "$ZNS_HOPS"
    return
  fi
  local home="$HOME"
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    if [[ -z "$home" ]]; then
    echo "could not find a home directory for $SUDO_USER" >&2
    return 1
    fi
  fi
  printf '%s\n' "$home/zns-hops"
}

# A current file directly in the parent belongs to one network and is
# visible to the other. Commands for that network stop until those files
# sit in the network directory.
refuse_shared_hops() {
  local base="$1" net="$2" recorded=""
  if [[ ! -f "$base/current" && ! -f "$base/network" ]]; then
    return 0
  fi
  if [[ -f "$base/network" ]]; then
    recorded="$(head -n 1 "$base/network")"
    recorded="${recorded//$'\r'/}"
  fi
  if [[ -n "$recorded" && "$recorded" != "$net" ]]; then
    return 0
  fi
  echo "$base holds this network's current beside the other network" >&2
  echo "stop that guest, then move network, current, images, logs, snapshots, upgrade-from-*, and transport-from-* into $base/${recorded:-$net}" >&2
  return 1
}

hops_network() {
  local hops="$1" net recorded
  net="$(require_network)" || return 1
  if [[ -z "$hops" ]]; then
    echo "network directory is missing" >&2
    return 1
  fi
  if [[ -f "$hops/network" ]]; then
    recorded="$(head -n 1 "$hops/network")"
    recorded="${recorded//$'\r'/}"
    if [[ "$recorded" != "$net" ]]; then
      echo "$hops/network is ${recorded}; ZNS_NETWORK is ${net}" >&2
      exit 1
    fi
  else
    mkdir -p "$hops"
    printf '%s\n' "$net" >"$hops/network.next"
    mv "$hops/network.next" "$hops/network"
  fi
  printf '%s\n' "$net"
}

hops_root() {
  local base net
  base="$(hops_base)" || return 1
  net="$(require_network)" || return 1
  refuse_shared_hops "$base" "$net" || return 1
  printf '%s\n' "$base/$net"
}

# tmux session for this network: zns-mainnet-source, zns-testnet-backup.
guest_session() {
  local role="$1" net
  case "$role" in
    source|target|previous|backup) ;;
    *)
      echo "unknown guest session ${role}" >&2
      return 1
      ;;
  esac
  net="$(require_network)" || return 1
  printf 'zns-%s-%s\n' "$net" "$role"
}

# QEMU -name for this network. The tag is the release, or backup.
guest_qemu_name() {
  local net
  net="$(require_network)" || return 1
  printf 'zns-%s-%s\n' "$net" "$1"
}

# Host ports. The guest still listens on 9465 and 9998.
# mainnet uses 9465/9999, 19465/19999, and 29465/29999.
# testnet uses 10465/10999, 20465/20999, and 30465/30999.
network_ports() {
  local role="$1" net mint zebra
  net="$(require_network)" || return 1
  case "${net}:${role}" in
    mainnet:genesis) mint=9465; zebra=9999 ;;
    mainnet:target) mint=19465; zebra=19999 ;;
    mainnet:backup) mint=29465; zebra=29999 ;;
    testnet:genesis) mint=10465; zebra=10999 ;;
    testnet:target) mint=20465; zebra=20999 ;;
    testnet:backup) mint=30465; zebra=30999 ;;
    *)
      echo "no host ports for ${net} ${role}" >&2
      return 1
      ;;
  esac
  if [[ -n "${ZNS_MINT_FWD:-}" ]]; then
    mint="$ZNS_MINT_FWD"
  fi
  if [[ -n "${ZNS_ZEBRA_FWD:-}" ]]; then
    zebra="$ZNS_ZEBRA_FWD"
  fi
  printf '%s %s\n' "$mint" "$zebra"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "run as root" >&2
    exit 1
  fi
}

require_tag() {
  local tag="$1"
  if [[ ! "$tag" =~ ^v[0-9][A-Za-z0-9._-]*$ ]]; then
    echo "version must be a v* tag, got ${tag}" >&2
    exit 1
  fi
}

# The snapshot index is downloaded. Its filename is used as a path by root.
require_snapshot_filename() {
  local name="$1"
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "snapshot filename is not a single name" >&2
    exit 1
  fi
}

read_current() {
  local hops="$1" cur
  if [[ ! -f "$hops/current" ]]; then
    echo "no $hops/current; run launch-genesis first" >&2
    exit 1
  fi
  cur="$(head -n 1 "$hops/current")"
  cur="${cur//$'\r'/}"
  require_tag "$cur"
  printf '%s\n' "$cur"
}

write_current() {
  local hops="$1" tag="$2"
  printf '%s\n' "$tag" >"$hops/current.next"
  mv "$hops/current.next" "$hops/current"
}

# The standby account creates the handshake files over SSH. Root QEMU writes
# the source side as mode 0644. The directory is mode 700 and owned by that
# account, so that account can enter and read those files. Other accounts
# cannot enter. The upgrade directory stays root-owned.
open_transport_dir() {
  local dir="$1" owner="${2:-}" group
  mkdir -p "$dir"
  if [[ -n "$owner" && "$owner" != "root" ]]; then
    group="$(id -gn "$owner")"
    chown "$owner:$group" "$dir"
  fi
  chmod 700 "$dir"
}

# GitHub CLI state belongs to the user who invoked sudo. Root's login is a
# different account and does not see that user's gh credentials.
operator_gh() {
  if ! command -v gh >/dev/null; then
    echo "missing gh" >&2
    exit 1
  fi
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    sudo -u "$SUDO_USER" -- gh "$@"
  else
    gh "$@"
  fi
}

# Sessions belong to the user who invoked sudo. Root's tmux is a different
# server and does not see zns-<network>-source.
operator_tmux() {
  if ! command -v tmux >/dev/null; then
    echo "missing tmux" >&2
    exit 1
  fi
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    sudo -u "$SUDO_USER" -- tmux "$@"
  else
    tmux "$@"
  fi
}

# Write one line onto a guest's serial console. The pane tty shows it
# without that line being typed into QEMU.
console_line() {
  local session="$1" text="$2" tty
  tty="$(operator_tmux display-message -p -t "$session" '#{pane_tty}' 2>/dev/null || true)"
  if [[ -n "$tty" && -w "$tty" ]]; then
    printf '%s\n' "$text" >"$tty" || true
  fi
  echo "$text"
}

# True when the pane in the session is the QEMU named zns-<tag>, or started it.
qemu_in_session() {
  local session="$1" tag="$2" pane pid cur hops=0 qname
  pane="$(operator_tmux display-message -p -t "$session" '#{pane_pid}' 2>/dev/null || true)"
  [[ "$pane" =~ ^[0-9]+$ ]] || return 1
  qname="$(guest_qemu_name "$tag")" || return 1
  pid="$(pgrep -af qemu-system-x86_64 | grep -F -- "-name ${qname} -nographic" | head -n 1 || true)"
  pid="${pid%% *}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  cur="$pid"
  while [[ "$cur" =~ ^[0-9]+$ && "$cur" != "0" && "$cur" != "1" && "$hops" -lt 20 ]]; do
    if [[ "$cur" == "$pane" ]]; then
      return 0
    fi
    cur="$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d '[:space:]' || true)"
    hops=$((hops + 1))
  done
  return 1
}

# The live guest occupies zns-<network>-source. The guest being moved
# occupies zns-<network>-target until receipt.bin, then takes that name.
# The previous guest keeps running as zns-<network>-previous until its
# session is closed. A missing target session is a finished rename only
# when that QEMU is already the source pane. Any other absence leaves
# current unchanged.
claim_source_session() {
  local from="$1" to="$2" retired=0 source target previous
  source="$(guest_session source)" || return 1
  target="$(guest_session target)" || return 1
  previous="$(guest_session previous)" || return 1
  if ! operator_tmux has-session -t "$target" 2>/dev/null; then
    if qemu_in_session "$source" "$to"; then
      echo "target qemu is already in tmux session ${source}"
      return 0
    fi
    echo "tmux session ${target} is missing; current stays ${from}." >&2
    return 1
  fi
  if operator_tmux has-session -t "$source" 2>/dev/null; then
    if operator_tmux has-session -t "$previous" 2>/dev/null; then
      echo "tmux session ${previous} already exists; the new guest stays in ${target}" >&2
      echo "current stays ${from}. Stop that guest, close ${previous}, and run migrate again." >&2
      return 1
    fi
    operator_tmux rename-session -t "$source" "$previous"
    console_line "$previous" "Switched from ${source} to ${previous} in tmux."
    console_line "$previous" "The version ${to} has the seed. Keep ${from} running until this console says this mint is stopped for good."
    retired=1
  fi
  operator_tmux rename-session -t "$target" "$source"
  console_line "$source" "Switched from ${target} to ${source} in tmux."
  if [[ "$retired" -eq 0 ]]; then
    echo "The version ${to} has the seed. Keep ${from} running until its console says this mint is stopped for good."
  fi
}

# migrate and launch-target choose their own disk files. A path supplied by
# the caller could be the live guest's image.
refuse_state_disk_overrides() {
  if [[ -n "${ZNS_STATE_IMG:-}${ZEBRA_STATE_IMG:-}${TARGET_ZNS_STATE_IMG:-}${TARGET_ZEBRA_STATE_IMG:-}" ]]; then
    echo "this command does not take state disk paths" >&2
    exit 1
  fi
}
