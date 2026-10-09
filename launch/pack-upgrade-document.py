#!/usr/bin/env python3
"""Pack the canonical upgrade document and the TOML migrate reads.

The byte layout is zns_canon::upgrade::canonical_encoding. The release
workflow attests upgrade.bin. from_measurement, seed_fingerprint, and
source_capsule_hash come from upgrade-source.toml or from the workflow
inputs. The new measurement, guest policy, and initrd hash come from
this build.
"""

import hashlib
import os
import pathlib
import struct
import subprocess
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "upgrade-source.toml"
BUILD = ROOT / "build"
VERSION = 1


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
    if value <= 0 or value > 0xFFFFFFFFFFFFFFFF:
        fail("guest policy must be a non-zero u64")
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

    sequence_text = pick("UPGRADE_SEQUENCE", "sequence", False) or "1"
    try:
        sequence = int(sequence_text, 0)
    except ValueError:
        fail(f"sequence {sequence_text!r} is not an integer")
    if sequence < 0 or sequence > 0xFFFFFFFFFFFFFFFF:
        fail("sequence must be a u64")
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
        "from_guest_policy": pick("UPGRADE_FROM_GUEST_POLICY", "from_guest_policy", False),
    }


def guest_policy():
    text = subprocess.check_output([str(ROOT / "launch" / "qemu-snp.sh"), "--print"], text=True)
    for line in text.splitlines():
        if line.startswith("guest_policy="):
            return policy(line.split("=", 1)[1])
    fail("launch parameters have no guest_policy")


def canonical(source, to_measurement, to_guest_policy, artifact_hash, release):
    from_guest_policy = (
        policy(source["from_guest_policy"]) if source["from_guest_policy"] else to_guest_policy
    )
    if from_guest_policy == 0 or to_guest_policy == 0:
        fail("guest policy must not be zero")
    parts = [
        struct.pack("<I", VERSION),
        struct.pack("<Q", source["sequence"]),
        source["from_measurement"],
        to_measurement,
        struct.pack("<Q", from_guest_policy),
        struct.pack("<Q", to_guest_policy),
        source["seed_fingerprint"],
        source["source_capsule_hash"],
        artifact_hash,
        struct.pack("<I", len(release.encode())),
        release.encode(),
    ]
    return b"".join(parts), from_guest_policy


def toml_text(source, to_measurement, from_guest_policy, to_guest_policy, artifact_hash, release):
    return (
        f"version = {VERSION}\n"
        f"sequence = {source['sequence']}\n"
        f'from_measurement = "{source["from_measurement"].hex()}"\n'
        f'to_measurement = "{to_measurement.hex()}"\n'
        f"from_guest_policy = {from_guest_policy:#x}\n"
        f"to_guest_policy = {to_guest_policy:#x}\n"
        f'seed_fingerprint = "{source["seed_fingerprint"].hex()}"\n'
        f'source_capsule_hash = "{source["source_capsule_hash"].hex()}"\n'
        f'artifact_hash = "{artifact_hash.hex()}"\n'
        f'release = "{release}"\n'
    )


def main():
    source = load_source()
    if "--check" in sys.argv[1:]:
        return
    release_name = os.environ.get("GITHUB_REF_NAME", "").strip()
    if not release_name:
        fail("GITHUB_REF_NAME is empty; this step runs on a v* tag")
    release = release_tag(release_name)
    measurement_path = BUILD / "snp-measurement.txt"
    initrd_path = BUILD / "zns-initrd.img"
    if not measurement_path.is_file() or not initrd_path.is_file():
        fail("snp-measurement.txt and zns-initrd.img must exist before packing")
    to_measurement = hex_bytes("to_measurement", measurement_path.read_text(), 48)
    to_guest_policy = guest_policy()
    artifact_hash = hashlib.sha256(initrd_path.read_bytes()).digest()
    document, from_guest_policy = canonical(
        source, to_measurement, to_guest_policy, artifact_hash, release
    )
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / "upgrade.bin").write_bytes(document)
    (BUILD / "upgrade.toml").write_text(
        toml_text(
            source,
            to_measurement,
            from_guest_policy,
            to_guest_policy,
            artifact_hash,
            release,
        )
    )


if __name__ == "__main__":
    main()
