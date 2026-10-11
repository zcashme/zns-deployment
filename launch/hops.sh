# Shared path and tag helpers for the launch commands.
#
# $ZNS_HOPS/current is the release tag of the guest that is live.
# It is a name, not a counter. migrate writes the next tag only after
# receipt.bin appears, and it does not compare version numbers.

hops_root() {
  if [[ -n "${ZNS_HOPS:-}" ]]; then
    printf '%s\n' "$ZNS_HOPS"
    return
  fi
  local home="$HOME"
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    if [[ -z "$home" ]]; then
      echo "could not find a home directory for $SUDO_USER" >&2
      exit 1
    fi
  fi
  printf '%s\n' "$home/zns-hops"
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
# server and does not see zns-source.
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
  local session="$1" tag="$2" pane pid cur hops=0
  pane="$(operator_tmux display-message -p -t "$session" '#{pane_pid}' 2>/dev/null || true)"
  [[ "$pane" =~ ^[0-9]+$ ]] || return 1
  pid="$(pgrep -af qemu-system-x86_64 | grep -F -- "-name zns-${tag} -nographic" | head -n 1 || true)"
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

# The live guest occupies zns-source. The guest being moved occupies
# zns-target until receipt.bin, then takes that name. The previous guest
# keeps running as zns-previous until its session is closed.
# A missing zns-target is a finished rename only when that QEMU is already
# the zns-source pane. Any other absence leaves current unchanged.
claim_source_session() {
  local from="$1" to="$2" retired=0
  if ! operator_tmux has-session -t zns-target 2>/dev/null; then
    if qemu_in_session zns-source "$to"; then
      echo "target qemu is already in tmux session zns-source"
      return 0
    fi
    echo "tmux session zns-target is missing; current stays ${from}." >&2
    return 1
  fi
  if operator_tmux has-session -t zns-source 2>/dev/null; then
    if operator_tmux has-session -t zns-previous 2>/dev/null; then
      echo "tmux session zns-previous already exists; the new guest stays in zns-target" >&2
      echo "current stays ${from}. Stop that guest, close zns-previous, and run migrate again." >&2
      return 1
    fi
    operator_tmux rename-session -t zns-source zns-previous
    console_line zns-previous "Switched from zns-source to zns-previous in tmux."
    console_line zns-previous "The version ${to} is up. This version ${from} can be safely retired."
    retired=1
  fi
  operator_tmux rename-session -t zns-target zns-source
  console_line zns-source "Switched from zns-target to zns-source in tmux."
  if [[ "$retired" -eq 0 ]]; then
    echo "The version ${to} is up. This version ${from} can be safely retired."
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
