#!/usr/bin/env bash
# Build the measured guest from versions.toml.
#
# Fetches the pinned repos, builds zns-mint, zns-keygen, zns-migrate, and
# zebrad, checks the Sapling parameters, and packs build/zns-initrd.img.
#
# Chain databases, the seed capsule, and logs stay off this image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS="$ROOT/versions.toml"
BUILD="$ROOT/build"
SRC="$BUILD/src"
STAGE="$BUILD/stage"
BIN="$BUILD/bin"
INCOMPLETE="$BUILD/INCOMPLETE"

notes=()
note_incomplete() {
  notes+=("$1")
}

toml_get() {
  local key="$1" line val
  line="$(grep -E "^${key}[[:space:]]*=" "$VERSIONS" | head -n 1 || true)"
  if [[ -z "$line" ]]; then
    echo "versions.toml is missing ${key}" >&2
    exit 1
  fi
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  val="${val#\"}"
  val="${val%\"}"
  printf '%s' "$val"
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 1
  fi
}

fetch_repo() {
  local name="$1" url="$2" commit="$3"
  local dest="$SRC/$name"
  mkdir -p "$SRC"
  if [[ ! -d "$dest/.git" ]]; then
    git init "$dest"
    git -C "$dest" remote add origin "$url"
  fi
  local current
  current="$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$current" != "$commit" ]]; then
    git -C "$dest" fetch --depth 1 origin "$commit"
    git -C "$dest" checkout --detach --force FETCH_HEAD
  fi
  current="$(git -C "$dest" rev-parse HEAD)"
  if [[ "$current" != "$commit" ]]; then
    echo "${name} is at ${current}, versions.toml pins ${commit}" >&2
    exit 1
  fi
}

lock_canon() {
  sed -n 's/.*zns-canon\.git?branch=main#\([0-9a-f][0-9a-f]*\).*/\1/p' "$1" | head -n 1
}

warn_canon_lock() {
  local name="$1" lock="$2" found
  found="$(lock_canon "$lock")"
  if [[ "$found" != "$CANON_COMMIT" ]]; then
    echo "TODO: ${name} Cargo.lock builds zns-canon ${found:-unknown}; versions.toml canon_commit is ${CANON_COMMIT}" >&2
    note_incomplete "${name} Cargo.lock zns-canon pin differs from canon_commit"
    exit 1
  fi
}

verify_sapling() {
  local dir="$1"
  python3 - "$dir" \
    "$(toml_get sapling_spend_blake2b512)" \
    "$(toml_get sapling_output_blake2b512)" \
    "$(toml_get sapling_spend_bytes)" \
    "$(toml_get sapling_output_bytes)" \
    "$(toml_get sapling_spend_sha256)" \
    "$(toml_get sapling_output_sha256)" <<'PY'
import hashlib
import pathlib
import sys

directory, spend_b2, output_b2, spend_len, output_len, spend_sha, output_sha = sys.argv[1:]
files = [
    ("sapling-spend.params", spend_b2, int(spend_len), spend_sha),
    ("sapling-output.params", output_b2, int(output_len), output_sha),
]
for name, expected_b2, expected_len, expected_sha in files:
    data = pathlib.Path(directory, name).read_bytes()
    if len(data) != expected_len:
        raise SystemExit(f"{name}: size {len(data)} != {expected_len}")
    got_b2 = hashlib.blake2b(data, digest_size=64).hexdigest()
    if got_b2 != expected_b2:
        raise SystemExit(f"{name}: blake2b-512 {got_b2} != {expected_b2}")
    got_sha = hashlib.sha256(data).hexdigest()
    if expected_sha:
        if got_sha != expected_sha:
            raise SystemExit(f"{name}: sha256 {got_sha} != {expected_sha}")
    else:
        print(f"TODO: pin sapling sha256 for {name}: {got_sha}")
PY
}

build_bin() {
  local dir="$1"
  shift
  (
    cd "$dir"
    cargo build --locked --release "$@"
  )
}

need git
need cargo
need curl
need python3
need protoc
need cmake

NETWORK="$(toml_get network)"
if [[ "$NETWORK" != "testnet" ]]; then
  echo "TODO: network=${NETWORK} is not wired. This guest is testnet." >&2
  exit 1
fi

if ! grep -q 'network = "Testnet"' "$ROOT/image/configs/zebrad.toml"; then
  echo "image/configs/zebrad.toml must set network = \"Testnet\"" >&2
  exit 1
fi
if ! grep -q 'indexer_listen_addr = "127.0.0.1:18230"' "$ROOT/image/configs/zebrad.toml"; then
  echo "image/configs/zebrad.toml must listen on 127.0.0.1:18230" >&2
  exit 1
fi

CANON_COMMIT="$(toml_get canon_commit)"
MINT_COMMIT="$(toml_get mint_commit)"
KEYGEN_COMMIT="$(toml_get keygen_commit)"
MIGRATE_COMMIT="$(toml_get migrate_commit)"
ZEBRA_COMMIT="$(toml_get zebra_commit)"
ZEBRA_VERSION="$(toml_get zebra_version)"
KERNEL_VERSION="$(toml_get kernel_version)"
RUST_VERSION="$(toml_get rust_version)"
# Fetched repos pin channel = "stable". Without this, rustup follows that
# file and the compiler drifts off rust_version.
export RUSTUP_TOOLCHAIN="$RUST_VERSION"
need rustc
rustc_version="$(rustc --version)"
cargo_version="$(cargo --version)"
case "$rustc_version" in
  "rustc ${RUST_VERSION} "*) ;;
  *)
    echo "rustc is ${rustc_version}, versions.toml pins ${RUST_VERSION}" >&2
    exit 1
    ;;
esac
case "$cargo_version" in
  "cargo ${RUST_VERSION} "*) ;;
  *)
    echo "cargo is ${cargo_version}, versions.toml pins ${RUST_VERSION}" >&2
    exit 1
    ;;
esac

fetch_repo zns-canon "$(toml_get canon_repo)" "$CANON_COMMIT"
fetch_repo zns-mint "$(toml_get mint_repo)" "$MINT_COMMIT"
fetch_repo zns-keygen "$(toml_get keygen_repo)" "$KEYGEN_COMMIT"
fetch_repo zns-migrate "$(toml_get migrate_repo)" "$MIGRATE_COMMIT"
fetch_repo zebra "$(toml_get zebra_repo)" "$ZEBRA_COMMIT"

warn_canon_lock zns-mint "$SRC/zns-mint/Cargo.lock"
warn_canon_lock zns-keygen "$SRC/zns-keygen/Cargo.lock"
warn_canon_lock zns-migrate "$SRC/zns-migrate/Cargo.lock"

zebra_pkg_version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$SRC/zebra/zebrad/Cargo.toml" | head -n 1)"
if [[ "$zebra_pkg_version" != "$ZEBRA_VERSION" ]]; then
  echo "zebrad Cargo.toml version is ${zebra_pkg_version}, versions.toml says ${ZEBRA_VERSION}" >&2
  exit 1
fi

build_bin "$SRC/zns-mint" --bin zns-mint --features testnet
build_bin "$SRC/zns-keygen" --bin zns-keygen --features testnet
build_bin "$SRC/zns-migrate" --bin zns-migrate
build_bin "$SRC/zebra" -p zebrad --features indexer

rm -rf "$STAGE" "$BIN"
mkdir -p "$BIN" \
  "$STAGE/usr/local/bin" \
  "$STAGE/etc/zebra" \
  "$STAGE/root/.zcash-params" \
  "$STAGE/scripts/init-premount" \
  "$STAGE/proc" "$STAGE/sys" "$STAGE/dev" "$STAGE/run" \
  "$STAGE/var/lib/zebra" "$STAGE/state" "$STAGE/tmp"

install -m 0755 "$SRC/zns-mint/target/release/zns-mint" "$BIN/zns-mint"
install -m 0755 "$SRC/zns-keygen/target/release/zns-keygen" "$BIN/zns-keygen"
install -m 0755 "$SRC/zns-migrate/target/release/zns-migrate" "$BIN/zns-migrate"
install -m 0755 "$SRC/zebra/target/release/zebrad" "$BIN/zebrad"
install -m 0755 "$BIN/zns-mint" "$BIN/zns-keygen" "$BIN/zns-migrate" "$BIN/zebrad" "$STAGE/usr/local/bin/"
install -m 0644 "$ROOT/image/configs/zebrad.toml" "$STAGE/etc/zebra/zebrad.toml"
install -m 0755 "$ROOT/image/initramfs/scripts/init-premount/zns-testnet" \
  "$STAGE/scripts/init-premount/zns-testnet"

cat >"$STAGE/init" <<'EOF'
#!/bin/sh
exec /scripts/init-premount/zns-testnet
EOF
chmod 0755 "$STAGE/init"

params="$STAGE/root/.zcash-params"
curl -fsSL -o "$params/sapling-spend.params" "$(toml_get sapling_spend_url)"
curl -fsSL -o "$params/sapling-output.params" "$(toml_get sapling_output_url)"
verify_sapling "$params"

kernel_sha="$(toml_get kernel_deb_sha256)"
if [[ -z "$kernel_sha" ]]; then
  echo "TODO: kernel_deb_sha256 is empty; not fetching linux-image-${KERNEL_VERSION}" >&2
  note_incomplete "kernel package linux-image-${KERNEL_VERSION} and its modules"
else
  echo "TODO: kernel package URL is not pinned" >&2
  note_incomplete "kernel package URL for linux-image-${KERNEL_VERSION}"
fi

note_incomplete "guest userspace for the init script (blkid, ip, ipconfig, wget, pidof, modprobe)"
note_incomplete "dynamic linker and shared libraries for the guest binaries"

mkdir -p "$BUILD"
python3 - "$STAGE" "$BUILD/zns-initrd.img" <<'PY'
import gzip
import io
import pathlib
import stat
import sys

stage = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])

def emit(ino, name, mode, data):
    name_b = name.encode() + b"\0"
    header = (
        f"{ino:08X}{mode:08X}{0:08X}{0:08X}{1:08X}{0:08X}"
        f"{len(data):08X}{0:08X}{0:08X}{0:08X}{0:08X}{len(name_b):08X}{0:08X}"
    )
    blob = b"070701" + header.encode() + name_b
    blob += b"\0" * ((4 - (len(blob) % 4)) % 4)
    blob += data
    blob += b"\0" * ((4 - (len(data) % 4)) % 4)
    return blob

paths = sorted(stage.rglob("*"))
ino = 1
chunks = [emit(ino, ".", stat.S_IFDIR | 0o755, b"")]
ino += 1
for path in paths:
    rel = path.relative_to(stage).as_posix()
    mode = path.stat().st_mode
    if path.is_dir():
        data = b""
        filemode = stat.S_IFDIR | 0o755
    elif path.is_file():
        data = path.read_bytes()
        filemode = stat.S_IFREG | (0o755 if mode & 0o111 else 0o644)
    else:
        raise SystemExit(f"unsupported initramfs entry: {path}")
    chunks.append(emit(ino, rel, filemode, data))
    ino += 1
chunks.append(emit(ino, "TRAILER!!!", 0, b""))

buf = io.BytesIO()
with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
    gz.write(b"".join(chunks))
blob = bytearray(buf.getvalue())
blob[9] = 255
out_path.write_bytes(blob)
PY

printf '%s\n' "${notes[@]}" >"$INCOMPLETE"
echo "wrote ${BUILD}/zns-initrd.img"
echo "open gaps:"
cat "$INCOMPLETE"
