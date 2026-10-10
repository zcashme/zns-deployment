//! Write the upgrade TOML and the bytes `zns_canon::upgrade::canonical_encoding` produces.
//!
//! The current guest supplies `from_measurement`, `from_guest_policy`,
//! `seed_fingerprint`, `source_capsule_hash`, and `sequence`. This build
//! supplies `to_measurement`, `to_guest_policy`, and `artifact_hash`.
//! `release` is the `v*` tag the workflow is running on. `version` is 1.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use sha2::{Digest, Sha256};
use zns_canon::upgrade::{canonical_encoding, UpgradeManifest};

const VERSION: u32 = 1;

fn main() {
    if let Err(message) = run() {
        eprintln!("{message}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .map_err(|error| format!("repository root: {error}"))?;
    let source = load_source(&root)?;
    let release = release_tag(&env_string("GITHUB_REF_NAME"))?;
    let build = root.join("build");
    let to_measurement = measurement_file(&build.join("snp-measurement.txt"))?;
    let to_guest_policy = launch_policy(&root)?;
    let initrd = fs::read(build.join("zns-initrd.img")).map_err(|_| {
        "snp-measurement.txt and zns-initrd.img must exist before packing".to_string()
    })?;
    let artifact_hash: [u8; 32] = Sha256::digest(&initrd).into();
    let manifest = UpgradeManifest {
        version: VERSION,
        sequence: source.sequence,
        from_measurement: source.from_measurement,
        to_measurement,
        from_guest_policy: source.from_guest_policy,
        to_guest_policy,
        seed_fingerprint: source.seed_fingerprint,
        source_capsule_hash: source.source_capsule_hash,
        artifact_hash,
        release: release.clone(),
    };
    let document = canonical_encoding(&manifest);
    fs::write(build.join("upgrade.bin"), &document).map_err(|error| error.to_string())?;
    fs::write(build.join("upgrade.toml"), toml_text(&manifest)).map_err(|error| error.to_string())?;
    Ok(())
}

struct Source {
    sequence: u64,
    from_measurement: [u8; 48],
    from_guest_policy: u64,
    seed_fingerprint: [u8; 32],
    source_capsule_hash: [u8; 32],
}

fn load_source(root: &Path) -> Result<Source, String> {
    let path = root.join("upgrade-source.toml");
    let file = if path.is_file() {
        let text = fs::read_to_string(&path).map_err(|error| error.to_string())?;
        toml::from_str::<toml::Table>(&text).map_err(|error| format!("upgrade-source.toml: {error}"))?
    } else {
        toml::Table::new()
    };
    Ok(Source {
        sequence: required_u64(&file, "sequence", "UPGRADE_SEQUENCE")?,
        from_measurement: hex_array(&file, "from_measurement", "UPGRADE_FROM_MEASUREMENT")?,
        from_guest_policy: required_policy(&file)?,
        seed_fingerprint: hex_array(&file, "seed_fingerprint", "UPGRADE_SEED_FINGERPRINT")?,
        source_capsule_hash: hex_array(
            &file,
            "source_capsule_hash",
            "UPGRADE_SOURCE_CAPSULE_HASH",
        )?,
    })
}

fn required_u64(file: &toml::Table, key: &str, env_name: &str) -> Result<u64, String> {
    let text = pick(file, key, env_name)?;
    let value = parse_int(&text).map_err(|_| format!("{key} {text:?} is not an integer"))?;
    let value = u64::try_from(value).map_err(|_| format!("{key} must be a u64"))?;
    toml_integer(key, value)
}

fn required_policy(file: &toml::Table) -> Result<u64, String> {
    let text = pick(file, "from_guest_policy", "UPGRADE_FROM_GUEST_POLICY")?;
    policy_value(&text)
}

fn pick(file: &toml::Table, key: &str, env_name: &str) -> Result<String, String> {
    let from_env = env_string(env_name);
    if !from_env.is_empty() {
        return Ok(from_env);
    }
    if let Some(value) = file.get(key) {
        return Ok(match value {
            toml::Value::String(text) => text.clone(),
            toml::Value::Integer(number) => number.to_string(),
            other => other.to_string(),
        });
    }
    Err(format!(
        "missing {key}. Put it in upgrade-source.toml before pushing the tag, or run this workflow on the tag and set that input."
    ))
}

fn hex_array<const N: usize>(
    file: &toml::Table,
    key: &str,
    env_name: &str,
) -> Result<[u8; N], String> {
    let text = pick(file, key, env_name)?;
    let data = hex_bytes(key, &text, N)?;
    let mut out = [0u8; N];
    out.copy_from_slice(&data);
    Ok(out)
}

fn hex_bytes(name: &str, text: &str, size: usize) -> Result<Vec<u8>, String> {
    let raw = text.trim().trim_start_matches("0x");
    let data = hex::decode(raw).map_err(|_| format!("{name} is not hex"))?;
    if data.len() != size {
        return Err(format!("{name} is {} bytes, expected {size}", data.len()));
    }
    if data.iter().all(|byte| *byte == 0) {
        return Err(format!("{name} must not be all zeros"));
    }
    Ok(data)
}

fn measurement_file(path: &Path) -> Result<[u8; 48], String> {
    let text = fs::read_to_string(path).map_err(|_| {
        "snp-measurement.txt and zns-initrd.img must exist before packing".to_string()
    })?;
    let data = hex_bytes("to_measurement", &text, 48)?;
    let mut out = [0u8; 48];
    out.copy_from_slice(&data);
    Ok(out)
}

fn launch_policy(root: &Path) -> Result<u64, String> {
    let output = Command::new(root.join("launch/qemu-snp.sh"))
        .arg("--print")
        .stderr(Stdio::inherit())
        .output()
        .map_err(|error| format!("launch parameters: {error}"))?;
    if !output.status.success() {
        return Err("launch parameters have no guest_policy".to_string());
    }
    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("guest_policy=") {
            return policy_value(value);
        }
    }
    Err("launch parameters have no guest_policy".to_string())
}

fn release_tag(tag: &str) -> Result<String, String> {
    let rest = tag.strip_prefix('v').unwrap_or("");
    let plain = !rest.is_empty()
        && !rest.contains("..")
        && rest
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-');
    if plain {
        return Ok(tag.to_string());
    }
    if tag.is_empty() {
        return Err("GITHUB_REF_NAME is empty; this step runs on a v* tag".to_string());
    }
    Err(format!("release must be a v* tag, got {tag:?}"))
}

fn toml_text(manifest: &UpgradeManifest) -> String {
    format!(
        "\
version = {VERSION}
sequence = {sequence}
from_measurement = \"{from_measurement}\"
to_measurement = \"{to_measurement}\"
from_guest_policy = {from_guest_policy:#x}
to_guest_policy = {to_guest_policy:#x}
seed_fingerprint = \"{seed_fingerprint}\"
source_capsule_hash = \"{source_capsule_hash}\"
artifact_hash = \"{artifact_hash}\"
release = \"{release}\"
",
        sequence = manifest.sequence,
        from_measurement = hex::encode(manifest.from_measurement),
        to_measurement = hex::encode(manifest.to_measurement),
        from_guest_policy = manifest.from_guest_policy,
        to_guest_policy = manifest.to_guest_policy,
        seed_fingerprint = hex::encode(manifest.seed_fingerprint),
        source_capsule_hash = hex::encode(manifest.source_capsule_hash),
        artifact_hash = hex::encode(manifest.artifact_hash),
        release = manifest.release,
    )
}

fn env_string(name: &str) -> String {
    env::var(name).unwrap_or_default().trim().to_string()
}

/// `toml` stores an integer as `i64`. A larger value cannot be read back.
fn toml_integer(name: &str, value: u64) -> Result<u64, String> {
    if value > i64::MAX as u64 {
        return Err(format!("{name} must fit in a TOML integer"));
    }
    Ok(value)
}

fn policy_value(text: &str) -> Result<u64, String> {
    let value = parse_int(text).map_err(|_| format!("guest policy {text:?} is not an integer"))?;
    let value = u64::try_from(value).map_err(|_| "guest policy must be a non-zero u64".to_string())?;
    if value == 0 {
        return Err("guest policy must be a non-zero u64".to_string());
    }
    toml_integer("guest policy", value)
}

fn parse_int(text: &str) -> Result<i128, ()> {
    let text = text.trim();
    if let Some(hex) = text
        .strip_prefix("0x")
        .or_else(|| text.strip_prefix("0X"))
    {
        return i128::from_str_radix(hex, 16).map_err(|_| ());
    }
    text.parse().map_err(|_| ())
}
