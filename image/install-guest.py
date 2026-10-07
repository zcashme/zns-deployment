#!/usr/bin/env python3
"""Copy pinned guest tools and shared libraries into the initrd stage.

The deb list is image/guest-debs.sha256. Files are taken from those
packages, not from the machine running the build. A guest binary whose
loader or DT_NEEDED entry is absent from the pins fails the build.
"""

import argparse
import gzip
import hashlib
import io
import lzma
import os
import pathlib
import shutil
import stat
import struct
import subprocess
import tarfile
import urllib.request

# ip, wget, grep, mkdir, mount, pidof, tail, and sleep are BusyBox applets,
# so they have no separate files.
TOOLS = ("blkid", "ipconfig", "modprobe", "busybox")
# PT_INTERP is /lib64/ld-linux-x86-64.so.2. The linker is usr/lib64/ld-linux-x86-64.so.2.
USRMERGE = {
    "bin": "usr/bin",
    "sbin": "usr/sbin",
    "lib": "usr/lib",
    "lib64": "usr/lib64",
}


def extract_deb(deb_path, dest):
    data = pathlib.Path(deb_path).read_bytes()
    if not data.startswith(b"!<arch>\n"):
        raise SystemExit(f"{deb_path} is not a deb archive")
    pos = 8
    while pos + 60 <= len(data):
        header = data[pos : pos + 60]
        name = header[:16].decode().strip()
        size = int(header[48:58].decode().strip())
        pos += 60
        body = data[pos : pos + size]
        pos += size + (size % 2)
        if not name.startswith("data.tar"):
            continue
        if name.endswith(".zst"):
            raw = subprocess.check_output(["zstd", "-dc"], input=body)
        elif name.endswith(".xz"):
            raw = lzma.decompress(body)
        elif name.endswith(".gz"):
            raw = gzip.decompress(body)
        elif name == "data.tar":
            raw = body
        else:
            raise SystemExit(f"unsupported deb member {name} in {deb_path}")
        dest.mkdir(parents=True, exist_ok=True)
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as tar:
            tar.extractall(dest, filter="data")
        return
    raise SystemExit(f"{deb_path} has no data.tar member")


def elf_info(path):
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2:
        return [], None
    endian = "<" if data[5] == 1 else ">"
    e_phoff = struct.unpack_from(endian + "Q", data, 32)[0]
    e_phentsize, e_phnum = struct.unpack_from(endian + "HH", data, 54)
    loads = []
    interp = None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, _, p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from(
            endian + "IIQQQQQQ", data, off
        )
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 3:
            interp = data[p_offset : p_offset + p_filesz].split(b"\0", 1)[0].decode()

    def vaddr_to_off(vaddr):
        for virt, offset, size in loads:
            if virt <= vaddr < virt + size:
                return offset + (vaddr - virt)
        return None

    e_shoff = struct.unpack_from(endian + "Q", data, 40)[0]
    e_shentsize, e_shnum = struct.unpack_from(endian + "HH", data, 58)
    needed = []
    for i in range(e_shnum):
        sh = e_shoff + i * e_shentsize
        sh_type = struct.unpack_from(endian + "I", data, sh + 4)[0]
        if sh_type != 6:
            continue
        sh_offset = struct.unpack_from(endian + "Q", data, sh + 24)[0]
        sh_size = struct.unpack_from(endian + "Q", data, sh + 32)[0]
        strtab_addr = None
        needed_offs = []
        for n in range(sh_size // 16):
            tag, val = struct.unpack_from(endian + "QQ", data, sh_offset + n * 16)
            if tag == 1:
                needed_offs.append(val)
            elif tag == 5:
                strtab_addr = val
        if strtab_addr is None:
            continue
        str_base = vaddr_to_off(strtab_addr)
        if str_base is None:
            continue
        for off in needed_offs:
            end = data.index(b"\0", str_base + off)
            needed.append(data[str_base + off : end].decode())
    return needed, interp


def read_pins(path):
    pins = []
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        sha, filename = line.split()
        pins.append((sha, filename))
    if not pins:
        raise SystemExit(f"{path} has no package pins")
    return pins


def download(archive, work, sha, filename):
    dest = work / "debs" / pathlib.Path(filename).name
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest() == sha:
        return dest
    url = archive.rstrip("/") + "/" + filename
    dest.write_bytes(urllib.request.urlopen(url, timeout=180).read())
    got = hashlib.sha256(dest.read_bytes()).hexdigest()
    if got != sha:
        raise SystemExit(f"{filename}: sha256 {got} != {sha}")
    return dest


def abs_candidates(abs_path):
    rel = abs_path.lstrip("/")
    found = [rel]
    for prefix in ("lib64/", "lib/", "bin/", "sbin/"):
        if rel.startswith(prefix):
            found.append("usr/" + rel)
    return found


def find_named(roots, name):
    hits = []
    for root in roots:
        for path in root.rglob(name):
            if path.name == name and not path.is_dir():
                hits.append(path)
    if not hits:
        return None
    def rank(path):
        text = path.as_posix()
        prefer = 0 if "x86_64-linux-gnu" in text else 1
        on_path = 0 if any(part in ("bin", "sbin") for part in path.parts) else 1
        return (on_path, prefer, text)
    hits.sort(key=rank)
    return hits[0]


def find_abs(roots, abs_path):
    for rel in abs_candidates(abs_path):
        for root in roots:
            cand = root / rel
            if cand.exists() or cand.is_symlink():
                return cand
    return None


def place(src, stage, pkg_root):
    rel = src.relative_to(pkg_root)
    dest = stage / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_symlink() or dest.exists():
        return dest
    if src.is_symlink():
        os.symlink(os.readlink(src), dest)
    else:
        dest.write_bytes(src.read_bytes())
        os.chmod(dest, src.lstat().st_mode & 0o777)
    return dest


def link_usrmerge(stage):
    for name, target in USRMERGE.items():
        dest = stage / name
        if dest.is_symlink():
            continue
        if dest.exists():
            raise SystemExit(f"{dest} exists and is not the usr merge symlink")
        os.symlink(target, dest)


def install_shell(stage):
    """/bin/sh is a symlink to this BusyBox."""
    binaries = [
        path
        for path in stage.rglob("busybox")
        if path.is_file() and not path.is_symlink()
    ]
    if len(binaries) != 1:
        raise SystemExit(f"expected one busybox binary, found {binaries}")
    src = binaries[0]
    dest = stage / "usr/bin/busybox"
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists() and not dest.is_symlink():
        os.symlink(os.path.relpath(src, dest.parent), dest)
    sh = stage / "usr/bin/sh"
    if not sh.exists() and not sh.is_symlink():
        os.symlink("busybox", sh)


def link_on_path(stage, tool, src_in_stage):
    """ipconfig is at usr/lib/klibc/bin, which is not on PATH."""
    parent = src_in_stage.relative_to(stage).parent.as_posix()
    if parent in {"bin", "sbin", "usr/bin", "usr/sbin", "usr/local/bin"}:
        return
    dest = stage / "usr/sbin" / tool
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() or dest.is_symlink():
        return
    rel = os.path.relpath(src_in_stage, dest.parent)
    os.symlink(rel, dest)


def close_over(start, roots, stage):
    queue = list(start)
    seen = set()
    while queue:
        src = pathlib.Path(queue.pop())
        key = str(src)
        if key in seen:
            continue
        seen.add(key)
        if not src.exists() and not src.is_symlink():
            raise SystemExit(f"guest file is missing: {src}")
        pkg_root = None
        for root in roots:
            try:
                src.relative_to(root)
            except ValueError:
                continue
            pkg_root = root
            break
        if pkg_root is None:
            raise SystemExit(f"guest file is not in a pinned package: {src}")
        placed = place(src, stage, pkg_root)
        if src.is_symlink():
            raw = os.readlink(src)
            if raw.startswith("/"):
                found = find_abs(roots, raw)
                if found is None:
                    raise SystemExit(f"symlink {src} target {raw} is not in the pinned debs")
                queue.append(found)
            else:
                queue.append(src.parent / raw)
            continue
        if not src.is_file():
            continue
        if stat.S_ISREG(src.lstat().st_mode) and src.stat().st_size >= 4:
            needed, interp = elf_info(src)
        else:
            needed, interp = [], None
        if interp:
            found = find_abs(roots, interp)
            if found is None:
                raise SystemExit(f"{src.name} interpreter {interp} is not in the pinned debs")
            queue.append(found)
        for soname in needed:
            found = find_named(roots, soname)
            if found is None:
                raise SystemExit(f"{src.name} needs {soname}, which is not in the pinned debs")
            queue.append(found)
        if placed.name in TOOLS:
            link_on_path(stage, placed.name, placed)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True)
    parser.add_argument("--debs", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--stage", required=True)
    parser.add_argument("--bin", action="append", default=[])
    args = parser.parse_args()

    work = pathlib.Path(args.work)
    stage = pathlib.Path(args.stage)
    stage.mkdir(parents=True, exist_ok=True)
    extract = work / "root"
    if extract.exists():
        shutil.rmtree(extract)
    extract.mkdir(parents=True)

    roots = []
    for sha, filename in read_pins(args.debs):
        deb = download(args.archive, work, sha, filename)
        dest = extract / pathlib.Path(filename).name
        extract_deb(deb, dest)
        roots.append(dest)

    starts = []
    for tool in TOOLS:
        found = find_named(roots, tool)
        if found is None:
            raise SystemExit(f"pinned debs do not contain {tool}")
        starts.append(found)
    for binary in args.bin:
        path = pathlib.Path(binary)
        if not path.is_file():
            raise SystemExit(f"guest binary is missing: {binary}")

    # --bin files are already in the stage. Copy only their libraries.
    link_usrmerge(stage)
    close_over(starts, roots, stage)
    for binary in args.bin:
        path = pathlib.Path(binary)
        needed, interp = elf_info(path)
        extra = []
        if interp:
            found = find_abs(roots, interp)
            if found is None:
                raise SystemExit(f"{path.name} interpreter {interp} is not in the pinned debs")
            extra.append(found)
        for soname in needed:
            found = find_named(roots, soname)
            if found is None:
                raise SystemExit(f"{path.name} needs {soname}, which is not in the pinned debs")
            extra.append(found)
        close_over(extra, roots, stage)
    install_shell(stage)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f"zstd failed while extracting a deb: {exc}") from exc
