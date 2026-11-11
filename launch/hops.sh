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

# Host forwards. The guest listens on 9465 (mint) and 9998 (zebra).
# Mainnet's service pairs are 9465/9999 and 19465/19999. Its backup pair
# is 29465/29999. Testnet's service pairs are 10465/10999 and 20465/20999.
# Its backup pair is 30465/30999. A guest keeps the forwards it was started
# with when its tmux session is renamed. The next service guest on that
# network takes the other service pair. Backup stays on the backup pair.
# ZNS_MINT_FWD and ZNS_ZEBRA_FWD together replace the choice.

# True when $2 appears as its own word in $1.
port_listed() {
  [[ " $1 " == *" $2 "* ]]
}

# Mint and zebra host ports from one QEMU command line.
# A forward looks like hostfwd=tcp:127.0.0.1:<host>-:<guest>.
# The guest side is 9465 for mint and 9998 for zebra.
parse_forward_ports() {
  local rest="$1" chunk host guest mint="" zebra=""
  while [[ "$rest" == *hostfwd=* ]]; do
    rest="${rest#*hostfwd=}"
    chunk="${rest%%,*}"
    chunk="${chunk%% *}"
    guest="${chunk##*:}"
    host="${chunk%:*}"
    host="${host##*:}"
    host="${host%-}"
    if [[ "$guest" == "9465" ]]; then
      mint="$host"
    elif [[ "$guest" == "9998" ]]; then
      zebra="$host"
    fi
  done
  printf '%s %s\n' "$mint" "$zebra"
}

# Every host port a running QEMU forwards, space separated.
qemu_forwarded_ports() {
  local line ports="" mint zebra
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    read -r mint zebra < <(parse_forward_ports "$line")
    if [[ -n "$mint" ]]; then
      ports+=" $mint"
    fi
    if [[ -n "$zebra" ]]; then
      ports+=" $zebra"
    fi
  done < <(pgrep -af qemu-system-x86_64 || true)
  printf '%s\n' "${ports# }"
}

# The service or backup pair for this launch.
# $1 is genesis, target, or backup.
# $2 and $3 are the live guest's mint and zebra host ports, or empty.
# $4 is the space-separated list of host ports already forwarded.
# The chosen pair is printed on stdout, and the reason on the next line.
# The same sentence also goes to stderr.
choose_ports() {
  local role="$1" held_m="${2:-}" held_z="${3:-}" busy="${4:-}" net
  local low_m low_z high_m high_z bak_m bak_z
  local want_m want_z alt_m="" alt_z="" why
  net="$(require_network)" || return 1
  case "$net" in
    mainnet)
      low_m=9465; low_z=9999
      high_m=19465; high_z=19999
      bak_m=29465; bak_z=29999
      ;;
    testnet)
      low_m=10465; low_z=10999
      high_m=20465; high_z=20999
      bak_m=30465; bak_z=30999
      ;;
    *)
      echo "no host ports for ${net}" >&2
      return 1
      ;;
  esac
  if [[ -n "${ZNS_MINT_FWD:-}" || -n "${ZNS_ZEBRA_FWD:-}" ]]; then
    if [[ -z "${ZNS_MINT_FWD:-}" || -z "${ZNS_ZEBRA_FWD:-}" ]]; then
      echo "set ZNS_MINT_FWD and ZNS_ZEBRA_FWD together" >&2
      return 1
    fi
    if port_listed "$busy" "$ZNS_MINT_FWD" || port_listed "$busy" "$ZNS_ZEBRA_FWD"; then
      echo "host ports ${ZNS_MINT_FWD}/${ZNS_ZEBRA_FWD} are already forwarded" >&2
      return 1
    fi
    echo "host ports: mint ${ZNS_MINT_FWD} zebra ${ZNS_ZEBRA_FWD} (${net}, from the environment)" >&2
    printf '%s %s\n%s\n' "$ZNS_MINT_FWD" "$ZNS_ZEBRA_FWD" "${net}, from the environment"
    return 0
  fi
  if [[ "$role" == "backup" ]]; then
    want_m=$bak_m
    want_z=$bak_z
    why="${net} backup pair"
  elif [[ "$role" == "genesis" ]]; then
    want_m=$low_m
    want_z=$low_z
    alt_m=$high_m
    alt_z=$high_z
    why="${net} low pair"
  elif [[ -z "$held_m" && -z "$held_z" ]]; then
    want_m=$low_m
    want_z=$low_z
    alt_m=$high_m
    alt_z=$high_z
    why="${net} low pair; no live guest ports"
  elif [[ "$held_m" == "$low_m" && "$held_z" == "$low_z" ]]; then
    want_m=$high_m
    want_z=$high_z
    alt_m=$low_m
    alt_z=$low_z
    why="${net} high pair; live guest holds ${held_m}/${held_z}"
  elif [[ "$held_m" == "$high_m" && "$held_z" == "$high_z" ]]; then
    want_m=$low_m
    want_z=$low_z
    alt_m=$high_m
    alt_z=$high_z
    why="${net} low pair; live guest holds ${held_m}/${held_z}"
  else
    want_m=$low_m
    want_z=$low_z
    alt_m=$high_m
    alt_z=$high_z
    why="${net} low pair; live guest holds ${held_m}/${held_z}, outside this network"
  fi
  if port_listed "$busy" "$want_m" || port_listed "$busy" "$want_z"; then
    if [[ -z "$alt_m" ]] || port_listed "$busy" "$alt_m" || port_listed "$busy" "$alt_z"; then
      echo "host ports ${want_m}/${want_z} are already forwarded" >&2
      return 1
    fi
    echo "host ports: mint ${alt_m} zebra ${alt_z} (${net}; ${want_m}/${want_z} already forwarded)" >&2
    printf '%s %s\n%s\n' "$alt_m" "$alt_z" "${net}; ${want_m}/${want_z} already forwarded"
    return 0
  fi
  echo "host ports: mint ${want_m} zebra ${want_z} (${why})" >&2
  printf '%s %s\n%s\n' "$want_m" "$want_z" "$why"
}

# Host ports for this launch. genesis and target alternate this network's
# two service pairs. backup uses the backup pair.
network_ports() {
  local role="$1" busy held_m="" held_z="" hops from name line
  case "$role" in
    genesis|target|backup) ;;
    *)
      echo "no host ports for role ${role}" >&2
      return 1
      ;;
  esac
  busy="$(qemu_forwarded_ports)"
  if [[ "$role" == "target" ]]; then
    hops="$(hops_root)" || return 1
    if [[ -f "$hops/current" ]]; then
      from="$(read_current "$hops")"
      name="$(guest_qemu_name "$from")" || return 1
      line="$(pgrep -af qemu-system-x86_64 | grep -F -- "-name ${name} -nographic" | head -n 1 || true)"
      if [[ -n "$line" ]]; then
        read -r held_m held_z < <(parse_forward_ports "$line")
        if [[ -z "$held_m" || -z "$held_z" ]]; then
          echo "could not read host ports for ${name}" >&2
          return 1
        fi
      fi
    fi
  fi
  choose_ports "$role" "$held_m" "$held_z" "$busy"
}

# Split the two lines from network_ports into mint_fwd, zebra_fwd, and port_why.
read_port_choice() {
  local pair="${1%%$'\n'*}"
  port_why="${1#*$'\n'}"
  if [[ "$port_why" == "$1" ]]; then
    port_why=""
  fi
  read -r mint_fwd zebra_fwd <<<"$pair"
}

# Append "<role> <mint> <zebra> <reason>" to logs/<tag>.ports.
# The reason names the network. A later start of this tag adds its own line.
# The same line is not written twice. A guest that is already running keeps
# the reason recorded at its start.
write_host_ports() {
  local hops="$1" tag="$2" role="$3" mint="$4" zebra="$5" why="${6:-}"
  local path line="" record="$3 $4 $5"
  if [[ -n "$why" ]]; then
    record="$record $why"
  fi
  mkdir -p "$hops/logs"
  path="$hops/logs/${tag}.ports"
  if [[ -f "$path" ]]; then
    line="$(tail -n 1 "$path" || true)"
    line="${line//$'\r'/}"
  fi
  if [[ "$line" == "$record" ]]; then
    return 0
  fi
  if [[ "$why" == "already running" && "$line" == "$role $mint $zebra"* ]]; then
    return 0
  fi
  printf '%s\n' "$record" >>"$path"
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    chown "$SUDO_USER" "$path" || true
  fi
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
