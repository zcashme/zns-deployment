# zns-deployment

Reproducible build of the ZNS SEV-SNP guest: the kernel, initramfs, and launch parameters whose bytes the TEE measures.

`zns-mint`, `zns-keygen`, `zns-canon`, and `zns-migrate` stay in their own repos. `versions.toml` pins the commits this image builds and the Rust toolchain that compiles them. Chain databases, the seed capsule, and logs stay on the host as runtime state.

```text
versions.toml
image/guest-debs.sha256
image/build-image.sh
image/configs/zebrad.toml
image/initramfs/scripts/init-premount/zns-testnet
launch/qemu-snp.sh
.github/workflows/release.yml
```

`image/build-image.sh` fetches those pins, builds the binaries, checks the Sapling parameters, and writes `build/zns-initrd.img`. `image/guest-debs.sha256` pins BusyBox, `blkid`, `ipconfig`, `kmod`, and the shared libraries. `versions.toml` also pins the kernel, its `sev-guest` module, and the OVMF firmware hash. `launch/qemu-snp.sh` is the launch configuration the SNP measurement has to use. The release workflow runs that build, hashes the artifacts, computes the expected measurement, writes a release manifest, attests the artifacts, and uploads them.
 
