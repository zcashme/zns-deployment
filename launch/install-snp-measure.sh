#!/usr/bin/env bash
# Install the pinned sev-snp-measure wheel into build/snp-measure-venv.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS="$ROOT/versions.toml"
BUILD="$ROOT/build"
VENV="$BUILD/snp-measure-venv"

pin_value() {
  local key="$1" line val
  line="$(grep -E "^${key}[[:space:]]*=" "$VERSIONS" | head -n 1 || true)"
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  val="${val#\"}"
  val="${val%\"}"
  printf '%s' "$val"
}

version="$(pin_value snp_measure_version)"
url="$(pin_value snp_measure_url)"
expected="$(pin_value snp_measure_sha256)"
if [[ -z "$version" || -z "$url" || -z "$expected" ]]; then
  echo "snp_measure_version, snp_measure_url, and snp_measure_sha256 must be set" >&2
  exit 1
fi

mkdir -p "$BUILD"
wheel="$BUILD/$(basename "$url")"
curl -fsSL -o "$wheel" "$url"
got="$(python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$wheel")"
if [[ "$got" != "$expected" ]]; then
  echo "sev-snp-measure sha256 ${got} != ${expected}" >&2
  exit 1
fi

python3 -m venv "$VENV"
"$VENV/bin/pip" install --disable-pip-version-check "$wheel"
installed="$("$VENV/bin/sev-snp-measure" --version)"
if [[ "$installed" != "sev-snp-measure ${version}" ]]; then
  echo "sev-snp-measure --version is ${installed}, versions.toml pins ${version}" >&2
  exit 1
fi
