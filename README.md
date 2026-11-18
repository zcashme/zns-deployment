# zns-deployment

Reproducible build of the ZNS SEV-SNP guest: the kernel, initramfs, and launch parameters whose bytes the TEE measures.

`zns-mint`, `zns-keygen`, `zns-canon`, and `zns-migrate` are one workspace in [zns-mint](https://github.com/zcashme/zns-mint). `versions.toml` pins the zns-mint and Zebra commits this image builds and the Rust toolchain that compiles them. Chain data, the seed capsule, and logs stay on the host.

## What the TEE measures

The digest covers the vCPU count, CPU family, model and stepping, guest features, OVMF, kernel, initrd, and kernel command line. Guest policy is reported next to the digest.

Memory size, the state disks, host port forwards, and 9p mounts are launch settings.

## Layout

| Path | Role |
| --- | --- |
| `versions.toml` | Networks, commits, toolchain, kernel, OVMF |
| `image/build-image.sh` | Fetch zns-mint and Zebra, build one network's binaries, write `build/zns-initrd.img` |
| `image/guest-debs.sha256` | BusyBox, kmod, and the shared libraries |
| `image/configs/zebrad.toml` | Zebra config baked into the initrd; the build fills in the network and ports |
| `image/initramfs/scripts/init-premount/zns` | PID 1 |
| `launch/guest-config.sh` | Settings shared by the measurement and the launch |
| `launch/measure-guest.sh` | Expected measurement |
| `launch/print-guest-config.sh` | Settings for the manifest and the upgrade packer |
| `launch/launch-guest.sh` | QEMU command |
| `launch/launch-genesis` | Fetch the release and boot the first guest, upgrade and transport directories mounted |
| `launch/fetch-release` | Download and verify one tag's files for this host's network |
| `launch/fetch-zebra-snapshot` | Download a Zebra snapshot this build can open |
| `launch/install-zebra-snapshot` | Put that snapshot on a new target Zebra disk |
| `launch/launch-target` | Boot the target guest against the live hop |
| `launch/migrate` | Fetch the release, boot the target, publish the upgrade, record the tag after `receipt.bin` |
| `launch/prepare-host` | Install QEMU, sshfs, tmux, gh, and the pinned kernel and OVMF |
| `.github/workflows/release.yml` | Build, measure, and attest each network; publish one release |

Each network has its own directory under the hops directory, `zns-hops/mainnet` and `zns-hops/testnet`. `current` in that directory is the tag of the live guest for that network. It advances when a migration writes `receipt.bin`. A later `migrate` may name an older tag. The same directory holds that network's images, logs, snapshots, and upgrade and transport directories.

## Networks

`versions.toml` lists `networks`. The same pins build one image per network: `zns-mint` and `zns-keygen` choose the network at compile time, and the image's Zebra config names it. Each network's image has its own measurement.

A tag push builds every network and publishes one release. Each network's files are named `zns-<network>-*`, for example `zns-testnet-initrd.img`. Running the workflow on a tag with a source guest's values and its network adds `zns-<network>-upgrade.bin` and `zns-<network>-upgrade.toml`. That run does not build: it packs the document against the initrd and measurement the tag already published. Running it with `from_measurement` set to that same measurement publishes `zns-<network>-backup.bin` and `zns-<network>-backup.toml` and leaves the upgrade document in place.

Every launch command takes `ZNS_NETWORK=mainnet` or `ZNS_NETWORK=testnet`. That selects the directory. A `current` file still sitting directly in `zns-hops` belongs to one network. Stop that guest, then move `network`, `current`, `images`, `logs`, `snapshots`, `upgrade-from-*`, and `transport-from-*` into `zns-hops/mainnet` or `zns-hops/testnet` before the next command for that network.

## Console

`launch-genesis` starts the guest in tmux session `zns-<network>-source`. That session is the guest serial console, and it is also appended to `logs/<tag>.console` in that network's directory. Attach with `tmux attach -t zns-mainnet-source` or `tmux attach -t zns-testnet-source`. Every 10 minutes the guest repeats the release it is running, whether Zebra is healthy and ready, the latest Zcash block, whether mint is up, memory available, and free space on the ZNS and Zebra disks.

`Ctrl-a c` switches to the QEMU monitor. `quit` stops the VM, and `Ctrl-a c` returns to the guest. `Ctrl-a x` stops it directly. This is the host powering the VM off. The guest policy keeps that monitor from reading guest memory.

Each network has two pairs of host ports. The guest itself listens on 9465 and 9998. Mainnet's pairs are mint `9465` with Zebra `9999`, and mint `19465` with Zebra `19999`. Testnet's pairs are mint `10465` with Zebra `10999`, and mint `20465` with Zebra `20999`. `launch-genesis` takes the low pair. Each migrate takes the other pair of that same network: the live guest keeps the forwards it was started with when its tmux session is renamed, so the next guest has to use the pair that is free. The launch command prints the pair, and appends a line to `logs/<tag>.ports` in that network's directory. The line is the role, `genesis` or `target`, then the mint port, the Zebra port, and the reason, which names the network. A later start of that tag adds another line. A backup guest stays on its own pair, mainnet `29465` and `29999`, testnet `30465` and `30999`. Set `ZNS_MINT_FWD` and `ZNS_ZEBRA_FWD` together to choose a pair by hand. A target guest starts in tmux session `zns-<network>-target`. Its console is also written to a log file.

## Moving a guest

Run this on the host, from a checkout of the release you are moving to or launching: `git checkout <tag>`. Signing in and out of GitHub is covered separately. The hops directory on this host is `/home/ubuntu/zns-hops/<network>`. The file `current` in that directory is the release that is live for that network.

The release has the initrd but not the kernel and OVMF. `launch-guest.sh` boots `build/vmlinuz` and `build/OVMF.amdsev.fd` from this checkout and refuses them unless they match `versions.toml`. `./image/build-image.sh <network>` writes both. Without a full build, take them from the pinned Ubuntu packages:

```bash
pin() { sed -n "s/^$1 = \"\(.*\)\"/\1/p" versions.toml; }
mkdir -p build/debs
curl -fsSL -o build/debs/kernel.deb "https://archive.ubuntu.com/ubuntu/$(pin kernel_image_deb)"
curl -fsSL -o build/debs/ovmf.deb "https://archive.ubuntu.com/ubuntu/$(pin ovmf_deb)"
echo "$(pin kernel_image_deb_sha256)  build/debs/kernel.deb" | sha256sum -c
echo "$(pin ovmf_deb_sha256)  build/debs/ovmf.deb" | sha256sum -c
dpkg-deb -x build/debs/kernel.deb build/debs/kernel
dpkg-deb -x build/debs/ovmf.deb build/debs/ovmf
cp "build/debs/kernel/boot/vmlinuz-$(pin kernel_version)" build/vmlinuz
cp build/debs/ovmf/usr/share/ovmf/OVMF.amdsev.fd build/OVMF.amdsev.fd
echo "$(pin kernel_vmlinuz_sha256)  build/vmlinuz" | sha256sum -c
echo "$(pin ovmf_fd_sha256)  build/OVMF.amdsev.fd" | sha256sum -c
```

The first guest is started once. Point it at the two disk images already on the host. This command does not create or replace them. It downloads and verifies the release's initrd for this network, starts the guest in tmux session `zns-<network>-source`, and writes the console to `logs/<tag>.console` in that network's directory.

```bash
sudo ZNS_NETWORK=testnet \
  ZNS_STATE_IMG=/home/ubuntu/zns-v0.1.x-state.img \
  ZEBRA_STATE_IMG=/home/ubuntu/zebra-state.img \
  ./launch/launch-genesis v0.1.x
tmux attach -t zns-testnet-source
```

Detach from tmux with `Ctrl-b d` if you need the shell back; the guest keeps running. The console prints the Treasury address to fund. Wait until it prints `ceremony complete`. The next line is the access-code public key. Write that line down. Each later boot prints it once.

To move that guest to another release, open a second terminal and run the command below. It stops immediately if that user is not logged in to GitHub.

```bash
sudo ZNS_NETWORK=testnet ./launch/migrate v0.1.x
```

Replace `v0.1.x` with the release you are moving to. An older tag is a rollback, and the command allows it. Run the command as shown. The disk variables from the first command belong only there; if they are still set, `migrate` exits before it starts. The new ZNS disk is an empty file under `/home/ubuntu/zns-hops/<network>/images/<new-tag>/`. The new Zebra disk is filled from the newest chain snapshot on [snapshots.zfnd.org](https://snapshots.zfnd.org/) that this Zebra can open, when that file does not already exist. If none can, the command stops before creating the disk. The live guest's disks are not copied. A file already in that directory is left unchanged. The download stays in `/home/ubuntu/zns-hops/<network>/snapshots/`. After the new guest's Zebra is syncing, that download can be deleted. The Zebra disk image stays.

Wait until the command prints `current is now v0.1.x`. That is the point at which the move has landed. The new guest's tmux session is then `zns-<network>-source`, and its console says so, including the host ports that guest keeps. The guest you started from is `zns-<network>-previous`, and its console names the host ports it keeps. Its mint keeps serving while the new guest syncs Zebra and scans its wallet. When that is done, the old console logs `this mint is stopped for good` and the new mint starts.

Pressing Ctrl-C while that command is still waiting stops only the wait. The new guest keeps running, in `zns-<network>-target`, and `current` stays on the old release. Run the same command again and it continues waiting. If it says `zns-<network>-previous` already exists, stop that guest, close the session, and run the same command again. If it says `zns-<network>-target` is missing, `current` stays on the old release unless the new guest is already the `zns-<network>-source` session.

Leave both guests running until the old console logs `this mint is stopped for good`. Until then the new guest's mint is paused, and quitting the old guest leaves no mint running. Do not restart the new guest before that line either: a restart without this hop's transport directory skips the pause, and both mints would serve. Then attach to the old one with `tmux attach -t zns-<network>-previous`, then `Ctrl-a c`, then `quit`, when you are ready to stop it. Detach with `Ctrl-b d`. The next move is another `migrate` from a second terminal. Do not restart the live guest for that.

Attach to the live guest with `tmux attach -t zns-<network>-source`. Its console is also `/home/ubuntu/zns-hops/<network>/logs/v0.1.x.console`. The host ports are the ones that launch printed. The last line of `logs/<tag>.ports` is the role, those two ports, and the reason. The next migrate uses the other pair for that network.

A copy of this same release onto another machine is the backup below. `current` stays on this release.

If `migrate` says the transport directory already has files, delete the files in `/home/ubuntu/zns-hops/<network>/transport-from-<old-tag>` and run `migrate` again. `current` stays on the old release until the move lands. Do not delete or recreate the live guest's disk images.

## Preparing a host

On a new machine, from a checkout of this release:

```bash
sudo ./launch/prepare-host
```

That installs QEMU, sshfs, tmux, gh, and the tools that format a disk and unpack a Zebra snapshot. It writes the pinned kernel and OVMF into `build/`. Signing in to GitHub is covered separately.

## Backup

A backup puts a second copy of the seed on a machine in another data centre, so the mint can be brought back if the live machine is lost. It is a migration to this same release: the live guest hands the seed to a standby guest, which seals it to its own chip and powers off. The stopped disk is the copy. `current` does not change. The live mint stops for the handoff and starts again after the receipt.

There is no command for this. The steps below are typed by hand on two machines.

### Rules

1. Both machines check out this release's tag. The launch scripts must be the ones from the release the guests run.
2. The standby ZNS disk is new and empty every time. A disk that holds `keys/zns_seed.capsule` starts a mint when it boots, also when it is booted as a backup target. Never boot such a disk while the live mint runs.
3. Start the standby guest before the document reaches the live guest. The live mint stops as soon as it sees the document and waits up to 24 hours for the standby.
4. Each backup needs its own document from the Release workflow, with a new `sequence`. The live guest treats a document it has already handed off as done.
5. A backup disk keeps working after the live guest moves to a later release. It still holds the seed. Keep it powered off unless the live machine is gone.

### Steps

Replace `testnet`, the tag, and the host name. Mainnet's backup ports are `29465` and `29999`.

1. On the standby machine, from this tag: `sudo ./launch/prepare-host`. Sign in to GitHub. Create the account's SSH key if it has none, and print it:

```bash
test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N "" -C "zns-backup@$(hostname)" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

2. On the live machine, as the account the standby logs in as, authorize that line. Then give that account the live transport directory. Root QEMU writes its handshake files as 0644, and only that account and root can enter the directory. The upgrade directory stays owned by root.

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<the ssh-ed25519 line>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
t=/home/ubuntu/zns-hops/testnet/transport-from-vX.Y.Z
sudo chown "$(id -un):$(id -gn)" "$t" && sudo chmod 700 "$t"
ls -A "$t"   # must print nothing
```

The live guest has to be one started on this tag, so it is mounted on `upgrade-from-<tag>` and `transport-from-<tag>`. `pgrep -af qemu-system | grep -o 'path=[^,]*'` shows its mounts. A guest that just finished `migrate` is still mounted on the previous tag's directories. Start it on this tag first.

3. On the live host, read the mint metrics at the mint port on the last line of `logs/<tag>.ports`. Mainnet is `9465` or `19465`. Testnet is `10465` or `20465`. `zns_mint_guest_info` carries `measurement` and `guest_policy`. `zns_mint_ceremony_info` carries `seed_fingerprint` and `capsule_hash`.

4. Run the Release workflow on this tag. Set `network` to this host's network. Set `from_measurement` to that `measurement` and `from_guest_policy` to that `guest_policy`. Set `seed_fingerprint` and `source_capsule_hash` to those labels. Set `sequence` to an integer this release has not used. The workflow packs `zns-<network>-backup.bin` for the initrd this tag already published. Wait until that file is on the release.

5. On the standby machine, mount the live directories over SSH. `/etc/fuse.conf` needs `user_allow_other`, which `prepare-host` writes.

```bash
net=testnet tag=vX.Y.Z live=ubuntu@<live-host>
m=/home/ubuntu/zns-hops/$net/backup-mount/$tag
mkdir -p "$m/upgrade" "$m/transport" && chmod 700 "/home/ubuntu/zns-hops/$net/backup-mount" "$m"
o=cache=no,attr_timeout=0,entry_timeout=0,allow_other,default_permissions,ServerAliveInterval=15
sshfs -o "$o" "$live:zns-hops/$net/upgrade-from-$tag" "$m/upgrade"
sshfs -o "$o" "$live:zns-hops/$net/transport-from-$tag" "$m/transport"
touch "$m/transport/.probe" && rm "$m/transport/.probe"
ls -A "$m/upgrade" "$m/transport"   # both must print nothing
```

6. On the standby machine, fetch the release and create the two disks. The first `test` stops here when a ZNS disk is already there. Do not delete it to get past this line: see rule 2.

```bash
d=/home/ubuntu/zns-hops/$net/images/$tag
test ! -e "$d/backup-zns-state.img" && test ! -e "$d/zebra-state.img"
sudo ZNS_NETWORK=$net ./launch/fetch-release "$tag"
sudo truncate -s 4G "$d/backup-zns-state.img" && sudo mkfs.ext4 -q -F "$d/backup-zns-state.img"
sudo ZNS_NETWORK=$net ./launch/install-zebra-snapshot "$tag"
sudo mv "$d/zebra-state.img" "$d/backup-zebra-state.img"
```

7. On the standby machine, start the guest and leave it waiting. The two `backup-next` directories are empty and stay empty.

```bash
n=/home/ubuntu/zns-hops/$net/backup-next/$tag
mkdir -p "$n/upgrade" "$n/transport" /home/ubuntu/zns-hops/$net/logs
tmux new-session -d -s zns-$net-backup "sudo env \
  ZNS_STATE_IMG=$d/backup-zns-state.img ZEBRA_STATE_IMG=$d/backup-zebra-state.img \
  INITRD=$d/release/zns-initrd.img ZNS_QEMU_NAME=zns-$net-backup \
  ZNS_MINT_FWD=30465 ZNS_ZEBRA_FWD=30999 \
  ZNS_9P='upgrade|$m/upgrade|ro;transport|$m/transport|rw;upgrade-next|$n/upgrade|ro;transport-next|$n/transport|rw' \
  $PWD/launch/launch-guest.sh"
tmux pipe-pane -t zns-$net-backup "cat >> /home/ubuntu/zns-hops/$net/logs/backup-$tag.console"
```

Wait until the console shows `migration watch started`.

8. On the live machine, put the backup document in the live guest's upgrade directory. `fetch-release` checks its attestation and refuses one whose two measurements differ. `upgrade.bin` is copied last, because the guest acts on it.

```bash
net=testnet tag=vX.Y.Z
sudo ZNS_NETWORK=$net ./launch/fetch-release "$tag"
r=/home/ubuntu/zns-hops/$net/images/$tag/release u=/home/ubuntu/zns-hops/$net/upgrade-from-$tag
sudo cp "$r/backup.toml" "$u/upgrade.toml"
sudo cp "$r/backup.bundle.jsonl" "$u/upgrade.bundle.jsonl"
sudo cp "$r/backup.bin" "$u/upgrade.bin.partial" && sudo mv "$u/upgrade.bin.partial" "$u/upgrade.bin"
```

9. On the standby console, wait until it logs `migration target finished` and the guest stops. The capsule is on `backup-zns-state.img`, sealed to that machine. On the live console, mint stops for the handoff, then the log says `same-release backup accepted; mint hold cleared` and mint starts again.

10. On the standby machine, close the session and unmount: `tmux kill-session -t zns-$net-backup; fusermount -u "$m/upgrade"; fusermount -u "$m/transport"`. On the live machine, once the live console says `Mint is up`, delete the handshake files from `transport-from-<tag>`. The next `migrate` from this tag refuses to start while they are there.

If the live guest restarts during the handoff, its mint stays stopped. Do not remove files by hand to bring it back. Ask first.

### Using the copy

Stop the live guest and leave that session closed. On the backup machine, start this same release with those two disks:

```bash
sudo ZNS_NETWORK=testnet \
  ZNS_STATE_IMG=/home/ubuntu/zns-hops/testnet/images/v0.1.x/backup-zns-state.img \
  ZEBRA_STATE_IMG=/home/ubuntu/zns-hops/testnet/images/v0.1.x/backup-zebra-state.img \
  ./launch/launch-genesis v0.1.x
```

That boot opens the capsule and starts mint. The live guest stays stopped, so one mint has the seed.
