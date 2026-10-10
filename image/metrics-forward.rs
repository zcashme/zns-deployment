//! Copy metrics connections from the guest's external ports to the loopback
//! ports where mint and Zebra listen. QEMU can forward an external port to
//! the host. It cannot forward 127.0.0.1.
//!
//! 0.0.0.0:9465 forwards to mint at 127.0.0.1:9464.
//! 0.0.0.0:9998 forwards to Zebra at 127.0.0.1:9999.

use std::io;
use std::net::{Shutdown, TcpListener, TcpStream};
use std::thread;

fn splice(mut left: TcpStream, mut right: TcpStream) {
    let Ok(mut left_back) = left.try_clone() else {
        return;
    };
    let Ok(mut right_back) = right.try_clone() else {
        return;
    };
    let outbound = thread::spawn(move || {
        let _ = io::copy(&mut left, &mut right);
        let _ = left.shutdown(Shutdown::Both);
        let _ = right.shutdown(Shutdown::Both);
    });
    let _ = io::copy(&mut right_back, &mut left_back);
    let _ = right_back.shutdown(Shutdown::Both);
    let _ = left_back.shutdown(Shutdown::Both);
    let _ = outbound.join();
}

fn serve(listen_port: u16, upstream_port: u16) {
    let listener = TcpListener::bind(("0.0.0.0", listen_port)).unwrap_or_else(|error| {
        eprintln!("[metrics] listen {listen_port}: {error}");
        std::process::exit(1);
    });
    eprintln!("[metrics] forwarding 0.0.0.0:{listen_port} to 127.0.0.1:{upstream_port}");
    for client in listener.incoming() {
        let Ok(client) = client else {
            continue;
        };
        thread::spawn(move || {
            if let Ok(upstream) = TcpStream::connect(("127.0.0.1", upstream_port)) {
                splice(client, upstream);
            }
        });
    }
}

fn main() {
    let mint = thread::spawn(|| serve(9465, 9464));
    let zebra = thread::spawn(|| serve(9998, 9999));
    let _ = mint.join();
    let _ = zebra.join();
    std::process::exit(1);
}
