#!/usr/bin/env python3
"""Check the source-guest fields before the image build.

The release job packs the canonical bytes later, with
zns_canon::upgrade::canonical_encoding. from_measurement,
from_guest_policy, seed_fingerprint, source_capsule_hash, and sequence
come from upgrade-source.toml or from the workflow inputs.
"""

import os
import pathlib
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "upgrade-source.toml"


def fail(message):
    raise SystemExit(message)


def hex_bytes(name, text, size):
    raw = text.strip().removeprefix("0x")
    try:
        data = bytes.fromhex(raw)
    except ValueError:
        fail(f"{name} is not hex")
    if len(data) != size:
        fail(f"{name} is {len(data)} bytes, expected {size}")
    if data == bytes(size):
        fail(f"{name} must not be all zeros")
    return data


def policy(text):
    try:
        value = int(text.strip(), 0)
    except ValueError:
        fail(f"guest policy {text!r} is not an integer")
    if value <= 0:
        fail("guest policy must be a non-zero u64")
    if value > 0x7FFFFFFFFFFFFFFF:
        fail("guest policy must fit in a TOML integer")
    return value


def release_tag(tag):
    rest = tag[1:] if tag.startswith("v") else ""
    plain = rest and ".." not in rest and all(
        c.isascii() and (c.isalnum() or c in "._-") for c in rest
    )
    if not plain:
        fail(f"release must be a v* tag, got {tag!r}")
    return tag


def load_source():
    file_values = {}
    if SOURCE.is_file():
        with SOURCE.open("rb") as handle:
            file_values = tomllib.load(handle)

    def pick(env_name, key, required):
        env = os.environ.get(env_name, "").strip()
        if env:
            return env
        if key in file_values:
            return str(file_values[key])
        if required:
            fail(
                f"missing {key}. Put it in upgrade-source.toml before pushing the tag, "
                "or run this workflow on the tag and set that input."
            )
        return ""

    sequence_text = pick("UPGRADE_SEQUENCE", "sequence", True)
    try:
        sequence = int(sequence_text, 0)
    except ValueError:
        fail(f"sequence {sequence_text!r} is not an integer")
    if sequence < 0 or sequence > 0x7FFFFFFFFFFFFFFF:
        fail("sequence must fit in a TOML integer")
    return {
        "sequence": sequence,
        "from_measurement": hex_bytes(
            "from_measurement", pick("UPGRADE_FROM_MEASUREMENT", "from_measurement", True), 48
        ),
        "seed_fingerprint": hex_bytes(
            "seed_fingerprint", pick("UPGRADE_SEED_FINGERPRINT", "seed_fingerprint", True), 32
        ),
        "source_capsule_hash": hex_bytes(
            "source_capsule_hash",
            pick("UPGRADE_SOURCE_CAPSULE_HASH", "source_capsule_hash", True),
            32,
        ),
        "from_guest_policy": pick("UPGRADE_FROM_GUEST_POLICY", "from_guest_policy", True),
    }


def main():
    source = load_source()
    policy(source["from_guest_policy"])
    release_name = os.environ.get("GITHUB_REF_NAME", "").strip()
    if not release_name:
        fail("GITHUB_REF_NAME is empty; this step runs on a v* tag")
    release_tag(release_name)
    if "--check" not in sys.argv[1:]:
        fail("canonical bytes are packed by launch/pack-upgrade after the image build")


if __name__ == "__main__":
    main()
