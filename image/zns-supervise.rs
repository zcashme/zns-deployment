//! Keep Zebra, mint, and the metrics forwarder running.
//!
//! Restart a process that has exited. After Zebra has passed /ready, or mint
//! has passed /metrics, restart that process once three checks fail. Leave
//! Zebra alone during its first sync. Start mint only while Zebra's /ready
//! check is succeeding and the ceremony is complete.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{SocketAddr, TcpStream};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

const CHECK_INTERVAL: u64 = 30;
const FAIL_LIMIT: i32 = 3;
const LOG_MAX: u64 = 64 * 1024 * 1024;
const LOG_KEEP: u64 = 8 * 1024 * 1024;
const COPY_BUF: usize = 64 * 1024;
const MINT_LOG: &str = "/state/log/mint.log";
const MINT_LOG_MAX: u64 = 1024 * 1024 * 1024;
const MINT_LOG_KEEP: u64 = MINT_LOG_MAX - LOG_MAX;
const LOGS: &[&str] = &[
    "/state/log/zebra.log",
    "/state/log/metrics.log",
    "/state/log/supervisor.log",
    "/state/log/keygen.log",
];
const WNOHANG: i32 = 1;
const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;

const ZEBRA: &str = "/usr/local/bin/zebrad";
const MINT: &str = "/usr/local/bin/zns-mint";
const FORWARD: &str = "/usr/local/bin/zns-forward";

extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
    fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
    fn setsid() -> i32;
    fn sync();
}

struct Watch {
    /// /ready has succeeded at least once. The first sync is left alone until then.
    zebra_seen_ready: bool,
    /// /ready succeeded on this check. Mint is started only while this is set.
    zebra_ready_now: bool,
    zebra_misses: i32,
    mint_ready: bool,
    mint_misses: i32,
}

fn log_msg(text: &str) {
    eprintln!("[supervise] {text}");
}

/// Once `path` is larger than `max`, keep its last `keep` bytes, starting
/// at the next line. Copy that tail toward the start of this same file, then
/// shorten the file. The writers still have it open for append, so the next
/// write continues at the new end.
fn cap_log(path: &str, max: u64, keep: u64) {
    let Ok(len) = std::fs::metadata(path).map(|meta| meta.len()) else {
        return;
    };
    if len <= max {
        return;
    }
    let Ok(mut file) = File::options().read(true).write(true).open(path) else {
        return;
    };
    let keep = keep.min(len);
    let mut start = len - keep;
    if file.seek(SeekFrom::Start(start)).is_err() {
        return;
    }
    let mut buf = [0u8; COPY_BUF];
    if let Ok(n) = file.read(&mut buf) {
        if let Some(pos) = buf[..n].iter().position(|byte| *byte == b'\n') {
            start += pos as u64 + 1;
        }
    }
    if start >= len {
        return;
    }
    // The kept tail starts more than one buffer past the beginning, so each
    // chunk is read before those bytes are overwritten.
    let mut src = start;
    let mut dst = 0u64;
    while src < len {
        if file.seek(SeekFrom::Start(src)).is_err() {
            return;
        }
        let want = ((len - src) as usize).min(COPY_BUF);
        let Ok(n) = file.read(&mut buf[..want]) else {
            return;
        };
        if n == 0 {
            break;
        }
        if file.seek(SeekFrom::Start(dst)).is_err() || file.write_all(&buf[..n]).is_err() {
            return;
        }
        src += n as u64;
        dst += n as u64;
    }
    if file.set_len(dst).is_err() {
        return;
    }
    log_msg(&format!("{path} was over {max} bytes; kept the last chunk"));
}

fn cap_logs() {
    cap_log(MINT_LOG, MINT_LOG_MAX, MINT_LOG_KEEP);
    for path in LOGS {
        cap_log(path, LOG_MAX, LOG_KEEP);
    }
}

fn cmdline_is(pid: i32, path: &str) -> bool {
    let Ok(bytes) = std::fs::read(format!("/proc/{pid}/cmdline")) else {
        return false;
    };
    let first = bytes.split(|byte| *byte == 0).next().unwrap_or(&[]);
    first == path.as_bytes()
}

fn is_zombie(pid: i32) -> bool {
    let Ok(text) = std::fs::read_to_string(format!("/proc/{pid}/status")) else {
        return true;
    };
    for line in text.lines() {
        let Some(rest) = line.strip_prefix("State:") else {
            continue;
        };
        let rest = rest.trim_start();
        return rest.starts_with('Z');
    }
    false
}

fn living_pid(path: &str) -> Option<i32> {
    let entries = std::fs::read_dir("/proc").ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(text) = name.to_str() else {
            continue;
        };
        let Ok(pid) = text.parse::<i32>() else {
            continue;
        };
        if pid <= 1 || is_zombie(pid) {
            continue;
        }
        if cmdline_is(pid, path) {
            return Some(pid);
        }
    }
    None
}

fn reap() {
    loop {
        let mut status = 0;
        let got = unsafe { waitpid(-1, &mut status, WNOHANG) };
        if got <= 0 {
            break;
        }
    }
}

/// Ask `pid` to exit, then kill it if it is still there.
/// `waitpid` only collects a child of this process. A supervisor that was
/// itself restarted is not the parent, so a failed `waitpid` does not mean
/// the process is gone. `kill(pid, 0)` is the check that does.
fn stop_pid(pid: i32) {
    if pid <= 1 {
        return;
    }
    let _ = unsafe { kill(pid, SIGTERM) };
    for _ in 0..50 {
        let mut status = 0;
        let got = unsafe { waitpid(pid, &mut status, WNOHANG) };
        if got == pid {
            return;
        }
        if unsafe { kill(pid, 0) } != 0 {
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }
    let _ = unsafe { kill(pid, SIGKILL) };
    for _ in 0..50 {
        let mut status = 0;
        let got = unsafe { waitpid(pid, &mut status, WNOHANG) };
        if got == pid || unsafe { kill(pid, 0) } != 0 {
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn spawn(log_path: &str, workdir: Option<&str>, args: &[&str]) {
    let mut cmd = Command::new(args[0]);
    cmd.args(&args[1..]).stdin(Stdio::null());
    if let Ok(log) = File::options().create(true).append(true).open(log_path) {
        if let Ok(errlog) = log.try_clone() {
            cmd.stdout(Stdio::from(log)).stderr(Stdio::from(errlog));
        }
    }
    if let Some(dir) = workdir {
        cmd.current_dir(dir);
    }
    unsafe {
        cmd.pre_exec(|| {
            let _ = setsid();
            Ok(())
        });
    }
    if let Err(error) = cmd.spawn() {
        eprintln!("[supervise] start {}: {error}", args[0]);
    }
}

fn http_ok(port: u16, path: &str) -> bool {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, Duration::from_secs(2)) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    let req = format!("GET {path} HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    if stream.write_all(req.as_bytes()).is_err() {
        return false;
    }
    let mut buf = [0u8; 64];
    let Ok(n) = stream.read(&mut buf) else {
        return false;
    };
    if n < 12 {
        return false;
    }
    let head = &buf[..n];
    head.starts_with(b"HTTP/1.0 200") || head.starts_with(b"HTTP/1.1 200")
}

fn ceremony_complete() -> bool {
    let Ok(text) = std::fs::read_to_string("/state/keys/ceremony_state.toml") else {
        return false;
    };
    text.lines().any(|line| line == "state = \"COMPLETE\"")
}

fn ensure_forward() {
    if living_pid(FORWARD).is_some() {
        return;
    }
    log_msg("starting metrics forwarder");
    spawn("/state/log/metrics.log", None, &[FORWARD]);
}

impl Watch {
    fn ensure_mint(&mut self) {
        if !self.zebra_ready_now || !ceremony_complete() {
            return;
        }
        let Some(pid) = living_pid(MINT) else {
            log_msg("starting mint");
            self.mint_ready = false;
            self.mint_misses = 0;
            spawn("/state/log/mint.log", Some("/state"), &[MINT]);
            return;
        };
        if http_ok(9464, "/metrics") {
            if !self.mint_ready {
                log_msg("mint metrics are up");
            }
            self.mint_ready = true;
            self.mint_misses = 0;
            return;
        }
        if !self.mint_ready {
            return;
        }
        self.mint_misses += 1;
        if self.mint_misses < FAIL_LIMIT {
            return;
        }
        log_msg("mint metrics failed, restarting mint");
        stop_pid(pid);
        self.mint_ready = false;
        self.mint_misses = 0;
        spawn("/state/log/mint.log", Some("/state"), &[MINT]);
    }

    fn ensure_zebra(&mut self) {
        let Some(pid) = living_pid(ZEBRA) else {
            log_msg("starting zebra");
            if let Some(mint) = living_pid(MINT) {
                stop_pid(mint);
            }
            self.zebra_seen_ready = false;
            self.zebra_ready_now = false;
            self.zebra_misses = 0;
            self.mint_ready = false;
            self.mint_misses = 0;
            spawn(
                "/state/log/zebra.log",
                None,
                &[ZEBRA, "-c", "/etc/zebra/zebrad.toml", "start"],
            );
            return;
        };
        if http_ok(8080, "/ready") {
            if !self.zebra_seen_ready {
                log_msg("zebra is ready");
            }
            self.zebra_seen_ready = true;
            self.zebra_ready_now = true;
            self.zebra_misses = 0;
            return;
        }
        self.zebra_ready_now = false;
        // The first sync has not passed /ready yet. Leave that process alone.
        if !self.zebra_seen_ready {
            return;
        }
        // /ready also requires a recent chain tip. /healthy only checks that
        // peers are connected. A stale tip is not a reason to restart Zebra.
        // Mint stays stopped until /ready succeeds.
        if http_ok(8080, "/healthy") {
            self.zebra_misses = 0;
            return;
        }
        self.zebra_misses += 1;
        if self.zebra_misses < FAIL_LIMIT {
            return;
        }
        log_msg("zebra is not healthy, restarting zebra and mint");
        stop_pid(pid);
        if let Some(mint) = living_pid(MINT) {
            stop_pid(mint);
        }
        self.zebra_seen_ready = false;
        self.zebra_ready_now = false;
        self.zebra_misses = 0;
        self.mint_ready = false;
        self.mint_misses = 0;
        spawn(
            "/state/log/zebra.log",
            None,
            &[ZEBRA, "-c", "/etc/zebra/zebrad.toml", "start"],
        );
    }
}

fn main() {
    let _ = std::fs::create_dir_all("/state/log");
    log_msg("supervisor started");
    let mut watch = Watch {
        zebra_seen_ready: false,
        zebra_ready_now: false,
        zebra_misses: 0,
        mint_ready: false,
        mint_misses: 0,
    };
    loop {
        reap();
        cap_logs();
        watch.ensure_zebra();
        ensure_forward();
        watch.ensure_mint();
        unsafe { sync() };
        thread::sleep(Duration::from_secs(CHECK_INTERVAL));
    }
}
