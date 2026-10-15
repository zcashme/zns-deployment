# zns-deployment

Reproducible build of the ZNS SEV-SNP guest: the kernel, initramfs, and launch parameters whose bytes the TEE measures.

`zns-mint`, `zns-keygen`, `zns-canon`, and `zns-migrate` live in their own repos. `versions.toml` pins the commits this image builds and the Rust toolchain that compiles them. Chain data, the seed capsule, and logs stay on the host.

## What the TEE measures

The digest covers the vCPU count, CPU family, model and stepping, guest features, OVMF, kernel, initrd, and kernel command line. Guest policy is reported next to the digest.

Memory size, the state disks, host port forwards, and 9p mounts are launch settings.

## Layout

| Path | Role |
| --- | --- |
| `versions.toml` | Networks, commits, toolchain, kernel, OVMF |
| `image/build-image.sh` | Fetch pins, build one network's binaries, write `build/zns-initrd.img` |
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
| `.github/workflows/release.yml` | Build, measure, and attest each network; publish one release |

The hops directory keeps `current`, the tag of the live guest. It advances when a migration writes `receipt.bin`. A later `migrate` may name an older tag. It also keeps `network`, the network this host serves.

## Networks

`versions.toml` lists `networks`. The same pins build one image per network: `zns-mint` and `zns-keygen` choose the network at compile time, and the image's Zebra config names it. Each network's image has its own measurement.

A tag push builds every network and publishes one release. Each network's files are named `zns-<network>-*`, for example `zns-testnet-initrd.img`. Running the workflow on a tag with a source guest's values builds that guest's network again and adds `zns-<network>-upgrade.bin` and `zns-<network>-upgrade.toml`.

A host serves one network. The first launch command run with `ZNS_NETWORK=mainnet` or `ZNS_NETWORK=testnet` records it in `network`, and later commands use the files for that network.

## Console

`launch-genesis` starts the guest in tmux session `zns-source`. That session is the guest serial console, and it is also appended to `logs/<tag>.console` in the hops directory. Attach with `tmux attach -t zns-source`. Every 10 minutes the guest repeats the release it is running, whether Zebra is healthy and ready, the latest Zcash block, whether mint is up, memory available, and free space on the ZNS and Zebra disks.

`Ctrl-a c` switches to the QEMU monitor. `quit` stops the VM, and `Ctrl-a c` returns to the guest. `Ctrl-a x` stops it directly. This is the host powering the VM off. The guest policy keeps that monitor from reading guest memory.

Zebra metrics are `127.0.0.1:9999/metrics`. Mint metrics are `127.0.0.1:9465/metrics` after the ceremony completes. A target guest starts in tmux session `zns-target` and uses `19465` and `19999`. Its console is also written to a log file.

## Moving a guest

Run this on the host, from a checkout of the release you are moving to. Signing in and out of GitHub is covered separately. The hops directory on this host is `/home/ubuntu/zns-hops`. The file `current` in that directory is the release that is live.

The first guest is started once. Point it at the two disk images already on the host. This command does not create or replace them. It downloads and verifies the release's initrd for this host's network, starts the guest in tmux session `zns-source`, and writes the console to `logs/<tag>.console` in the hops directory.

```bash
sudo ZNS_NETWORK=testnet \
  ZNS_STATE_IMG=/home/ubuntu/zns-v0.1.x-state.img \
  ZEBRA_STATE_IMG=/home/ubuntu/zebra-state.img \
  ./launch/launch-genesis v0.1.x
tmux attach -t zns-source
```

Detach from tmux with `Ctrl-b d` if you need the shell back; the guest keeps running. The console prints the Treasury address to fund. Wait until it prints `ceremony complete`. The next line is the access-code public key. Write that line down. Each later boot prints it once.

To move that guest to another release, open a second terminal and run the command below. It stops immediately if that user is not logged in to GitHub.

```bash
sudo ./launch/migrate v0.1.x
```

Replace `v0.1.x` with the release you are moving to. An older tag is a rollback, and the command allows it. Run the command as shown. The disk variables from the first command belong only there; if they are still set, `migrate` exits before it starts. The new ZNS disk is an empty file under `/home/ubuntu/zns-hops/images/<new-tag>/`. The new Zebra disk is filled from the newest chain snapshot on [snapshots.zfnd.org](https://snapshots.zfnd.org/) that this Zebra can open, when that file does not already exist. If none can, the command stops before creating the disk. The live guest's disks are not copied. A file already in that directory is left unchanged. The download stays in `/home/ubuntu/zns-hops/snapshots/`. After the new guest's Zebra is syncing, that download can be deleted. The Zebra disk image stays.

Wait until the command prints `current is now v0.1.x`. That is the point at which the move has landed. The new guest's tmux session is then `zns-source`, and its console says so. The guest you started from is `zns-previous`. Its console says the new version is up and that this one can be retired.

Pressing Ctrl-C while that command is still waiting stops only the wait. The new guest keeps running, in `zns-target`, and `current` stays on the old release. Run the same command again and it continues waiting. If it says `zns-previous` already exists, stop that guest, close the session, and run the same command again. If it says `zns-target` is missing, `current` stays on the old release unless the new guest is already the `zns-source` session.

Leave the new guest running. Attach to the old one with `tmux attach -t zns-previous`, then `Ctrl-a c`, then `quit`, when you are ready to stop it. Detach with `Ctrl-b d`. The next move is another `migrate` from a second terminal. Do not restart the live guest for that.

Attach to the live guest with `tmux attach -t zns-source`. Its console is also `/home/ubuntu/zns-hops/logs/v0.1.x.console`. Its metrics are `127.0.0.1:19465/metrics` and `127.0.0.1:19999/metrics`.

If `migrate` says the transport directory already has files, delete the files in `/home/ubuntu/zns-hops/transport-from-<old-tag>` and run `migrate` again. `current` stays on the old release until the move lands. Do not delete or recreate the live guest's disk images.
