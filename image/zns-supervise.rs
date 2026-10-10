//! Keep zebrad, zns-mint, and the metrics forwarder running.
//! Restart a process that exits. Restart one that was healthy and then fails
//! three checks. Leave Zebra alone while it is still syncing.
//!
//! Built with the pinned rustc from versions.toml. No host C compiler.

use std::fs::File;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

const CHECK_INTERVAL: u64 = 30;
const FAIL_LIMIT: i32 = 3;
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
    zebra_ready: bool,
    zebra_misses: i32,
    mint_ready: bool,
    mint_misses: i32,
}

fn log_msg(text: &str) {
    eprintln!("[supervise] {text}");
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

/// ECHILD means this supervisor was restarted and does not own the process.
/// That is not proof the process exited. Only a collected child or a failed
/// `kill(pid, 0)` ends the wait.
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
        if !self.zebra_ready || !ceremony_complete() {
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
            self.zebra_ready = false;
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
            if !self.zebra_ready {
                log_msg("zebra is ready");
            }
            self.zebra_ready = true;
            self.zebra_misses = 0;
            return;
        }
        if !self.zebra_ready {
            return;
        }
        self.zebra_misses += 1;
        if self.zebra_misses < FAIL_LIMIT {
            return;
        }
        log_msg("zebra lost readiness, restarting zebra and mint");
        stop_pid(pid);
        if let Some(mint) = living_pid(MINT) {
            stop_pid(mint);
        }
        self.zebra_ready = false;
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
        zebra_ready: false,
        zebra_misses: 0,
        mint_ready: false,
        mint_misses: 0,
    };
    loop {
        reap();
        watch.ensure_zebra();
        ensure_forward();
        watch.ensure_mint();
        unsafe { sync() };
        thread::sleep(Duration::from_secs(CHECK_INTERVAL));
    }
}
