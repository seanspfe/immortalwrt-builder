# immortalwrt-builder

Reproducible ImmortalWrt firmware for two machines, both carrying **honk** (the
eBPF transparent proxy) and the **Vantage** LuCI theme, built by GitHub Actions
from pinned upstream commits:

| Target | Image | Device |
| --- | --- | --- |
| `x86_64` | `immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz` (BIOS + UEFI) | generic PC / VM |
| `gl-mt3000` | `immortalwrt-mediatek-filogic-glinet_gl-mt3000-squashfs-sysupgrade.bin` | GL.iNet GL-MT3000 (MediaTek MT7981) |

Nothing is built automatically: `.github/workflows/build.yml` only runs from the
**Run workflow** button (or `gh workflow run`). A full build takes roughly 1.5–3
hours per target on a standard runner.

## Pinned versions

Every pin is checked out and verified against its commit at build time, so a
moved tag fails the build instead of silently changing the firmware.

| Component | Version | Commit | Where it comes from |
| --- | --- | --- | --- |
| ImmortalWrt | tag `v25.12.2` | `4fc16f2985a358bd43bb522e43f05395fcbd6ed5` | `immortalwrt/immortalwrt` |
| Linux kernel | `6.12.103` | — | `target/linux/generic/kernel-6.12` (`LINUX_VERSION-6.12 = .103`); both targets use `KERNEL_PATCHVER:=6.12` |
| honk | tag `v0.1.0-beta.6` | `64848881b7304e250e7a25422f4f1d86a5975eca` | `daeuniverse/honk` |
| honk packages (LuCI app, `luci-lib-daeuniverse`, `vmlinux-btf*`) | commit | `6157f709f52cdbf34c39e5fb69f4b81f468c10e6` | `daeuniverse/openwrt-packages` |
| doona panel (embedded in honk's native UI) | `0.1.0-rc.6` | `4c1f6f3fc1523558d595c363ba677494844030e3` | `Zakkaus/doona`, pinned by honk's `.github/ci/pins.env` |
| Vantage theme | tag `v1.0.14` | `cddbfb262b7a67a0d3762039e4af66fc0ac92000` | `anothaDev/luci-theme-vantage` |
| bpf-linker | `v0.11.0` | prebuilt `bpf-linker-x86_64-unknown-linux-musl.tar.zst` (SHA-256 `10f62ba9ab7e544d538370552660efcb4f1a19153d5752bbf0f6b51f3bada450`) | `aya-rs/bpf-linker` |
| Rust (honk-core) | `1.99.1` | — | `rust-toolchain.toml` of honk `v0.1.0-beta.6` |
| Rust (eBPF object) | `nightly-2026-10-20` | — | `crates/honk-ebpf/rust-toolchain.toml` of honk `v0.1.0-beta.6` |

kernel 6.12 is honk's floor (it requires Linux ≥ 6.12); `scripts/prepare-tree.sh`
refuses to continue if the checked-out tree does not report 6.12.103.

## What is in the image

Both targets integrate, as `=y` in the rootfs (no packages to install later):

- `honk` — the eBPF engine, built with the crate defaults (`clash-api`,
  `mimalloc`, `rprx`) plus `ebpf` and `native-ui`; `native-ui` embeds the pinned
  doona dashboard, served at `/ui` on the native API listener.
- `luci-app-honk` — LuCI page (config editor, service log, start/stop).
- `luci-lib-daeuniverse` — the shared LuCI library the page is built on.
- `vmlinux-btf-builtin` — the stand-in that satisfies honk's `vmlinux-btf`
  dependency on a kernel that carries its own BTF (see below).
- honk runtime dependencies: `libstdcpp`, `kmod-veth`, `kmod-sched-core`,
  `kmod-sched-bpf`, `kmod-nft-core`, `kmod-nft-queue`, `kmod-nfnetlink-queue`,
  `kmod-nf-conntrack`, `v2ray-geoip`, `v2ray-geosite`, `nftables-json`,
  `firewall4`.
- `luci-theme-vantage` and `luci-i18n-vantage-theme-zh-cn`. On a fresh install
  the theme registers itself and becomes the selected theme.

`x86_64` additionally ships the wired NIC drivers `kmod-e100`, `kmod-e1000`,
`kmod-e1000e`, `kmod-igb`, `kmod-igbvf`, `kmod-igc`, `kmod-r8169`,
`kmod-vmxnet3`, `kmod-tg3`, `kmod-forcedeth`, `kmod-bnx2`, `kmod-ixgbe`,
`kmod-i40e`. The virtual NICs need no packages: `CONFIG_VIRTIO_NET=y` and
`CONFIG_VIRTIO_PCI=y` are built into `target/linux/x86/64/config-6.12`, and
ImmortalWrt has no `kmod-virtio-net` / `kmod-virtio-pci` packages at all.

`gl-mt3000` uses device profile `mediatek/filogic` →
`DEVICE_glinet_gl-mt3000` with its radios, USB and storage packages:
`kmod-mt7915e`, `kmod-mt7981-firmware`, `mt7981-wo-firmware`,
`kmod-hwmon-pwmfan`, `kmod-usb3`, `automount`.

### Excluded on purpose

- **ua3f** — not selected; it is not part of ImmortalWrt, so it only has to stay
  out of the package list.
- **bridger** — ImmortalWrt's filogic target adds `bridger` to
  `DEFAULT_PACKAGES` (`target/linux/mediatek/filogic/target.mk`). That list is a
  make variable, so `CONFIG_PACKAGE_bridger is not set` would not remove it;
  `scripts/prepare-tree.sh` takes the word out of that line instead, and
  `scripts/verify-manifest.sh` fails the build if `bridger` shows up in the
  image.
- **OpenWrt's internal `golang` package** — nothing here needs it (honk is Rust),
  and the verify scripts fail if it lands in the image.

## Build with GitHub Actions

1. Open the **Actions** tab → **Build firmware** → **Run workflow**.
2. Pick `target`: `x86_64`, `gl-mt3000`, or `both`. `cargo_jobs` (default `2`)
   controls honk's cargo parallelism; lower it if the Rust link step runs out of
   memory, raise it on a bigger runner.
3. The job downloads two artifacts per target:
   - `immortalwrt-25.12.2-<target>` — images, `*.manifest`, `*.buildinfo`,
     `sha256sums`, `profiles.json`;
   - `immortalwrt-25.12.2-<target>-config-log` — the resolved diffconfig and the
     full build log.

From a terminal:

```sh
gh workflow run build.yml -f target=both
gh run watch
```

### What the workflow does

1. Frees ~40 GB on the runner (dotnet, Android SDK, GHC, CodeQL, swap).
2. Installs the host build dependencies plus `clang`, `libclang-dev`, `cmake`,
   `llvm` and `zstd`, which honk's build needs (bindgen, BoringSSL).
3. Installs Rust `1.99.1` and `nightly-2026-10-20`, both with the
   `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl` targets, and
   unpacks the pinned `bpf-linker` into `~/.cargo/bin`. `RUSTUP_TOOLCHAIN` is
   deliberately left unset so the rust-toolchain files inside honk decide.
4. `scripts/prepare-tree.sh` checks out ImmortalWrt, the package feed, the theme
   and honk at the pinned commits, applies the packaging patches, wires both
   external feeds and installs the feeds.
5. Copies `configs/<target>.config` over `.config`, runs `make defconfig`, and
   verifies every required symbol with `scripts/verify-config.sh`.
6. `make download`, then `make -j$(nproc)`.
7. `scripts/verify-manifest.sh` checks the built manifest (required packages
   present, excluded ones absent, kernel really built with BTF).

## Local build

Same tree, same steps; only the runner-specific bits (disk cleanup, artifact
upload) are left out:

```sh
git clone https://github.com/seanspfe/immortalwrt-builder.git
cd immortalwrt-builder

# host deps: build-essential clang cmake flex bison gawk gettext git
#            libclang-dev libelf-dev libncurses-dev libssl-dev llvm pkg-config
#            python3 rsync unzip zstd
rustup toolchain install 1.99.1 --profile minimal \
  --component rustfmt --component clippy \
  --target x86_64-unknown-linux-musl --target aarch64-unknown-linux-musl
rustup toolchain install nightly-2026-10-20 --profile minimal \
  --component rust-src --component llvm-tools \
  --target x86_64-unknown-linux-musl --target aarch64-unknown-linux-musl
rustup default 1.99.1
curl -fsSL -o /tmp/bpf-linker.tar.zst \
  https://github.com/aya-rs/bpf-linker/releases/download/v0.11.0/bpf-linker-x86_64-unknown-linux-musl.tar.zst
zstd -dc /tmp/bpf-linker.tar.zst | tar -xf - -C "$HOME/.cargo/bin"

./scripts/prepare-tree.sh
cd .src/immortalwrt
cp ../../configs/x86_64.config .config     # or gl-mt3000.config
make defconfig
../../scripts/verify-config.sh x86_64 "$PWD"
make download -j"$(nproc)"
make -j"$(nproc)"
../../scripts/verify-manifest.sh x86_64 "$PWD"
```

Images land in `.src/immortalwrt/bin/targets/<target>/`.

## Repository layout

```
.github/workflows/build.yml     manual build: cleanup, toolchains, build, verify, artifacts
configs/x86_64.config           seed config for x86/64 (squashfs + combined-EFI)
configs/gl-mt3000.config        seed config for mediatek/filogic GL-MT3000
patches/honk-package-build-env.patch
                                pinned honk version + Rust build environment in the package Makefile
scripts/prepare-tree.sh         pinned checkouts, patches, feeds
scripts/verify-config.sh        asserts the merged .config before compiling
scripts/verify-manifest.sh      asserts the built image after compiling
```

A seed config is not a full `.config`: it only lists the deviations that matter,
and `make defconfig` fills in everything else. That keeps it small enough to
read and stable when ImmortalWrt moves.

## How the pieces fit

### Kernel BTF

honk's eBPF datapath uses CO-RE, so the running kernel has to expose
`/sys/kernel/btf/vmlinux`. ImmortalWrt only enables that for its own buildbot:
`KERNEL_DEBUG_INFO_BTF` defaults to `y` only when `BUILDBOT` is set, and
`KERNEL_DEBUG_INFO_REDUCED` defaults to `y` whenever `BUILDBOT` is *not* set —
which silently disables BTF, because BTF depends on
`!KERNEL_DEBUG_INFO_REDUCED`. Both configs therefore set, explicitly:

```
CONFIG_KERNEL_DEBUG_INFO=y
# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES=y
CONFIG_KERNEL_MODULE_ALLOW_BTF_MISMATCH=y
```

Because the kernel carries its own BTF, no detached blob is installed:
`vmlinux-btf-builtin` provides `vmlinux-btf` (the dependency honk declares) and
the real `vmlinux-btf` package, which only installs for the exact SDK kernel it
was built from, stays out.

### honk's package Makefile

`patches/honk-package-build-env.patch` configures the Rust build environment in
`daeuniverse/openwrt-packages`' `honk/Makefile`:

`Build/Compile` exports `RUSTUP_HOME`, `CARGO_HOME` and `PATH` pointing at `~/.rustup`,
`~/.cargo` and `~/.cargo/bin`, sets `CARGO_PROFILE_RELEASE_LTO=false` and
`CARGO_BUILD_JOBS` (default `2`), dynamically resolves target cross compilers and
architecture strings, and invokes `/bin/bash "$(PKG_DIR)/build.sh"` directly.

### Feeds

Two external feeds are added to `feeds.conf.default` as `src-link` entries:
`openwrt_packages` (`daeuniverse/openwrt-packages`) and `luci_vantage`
(`anothaDev/luci-theme-vantage`). honk's sources are not a feed of their own:
its package Makefile builds from `honk/src`, so the pinned honk checkout is
placed there.

## Roll-forward checklist

To move a pin: change it in `.github/workflows/build.yml` **and** in the defaults
at the top of `scripts/prepare-tree.sh`, then update the table above. When honk
moves past beta.4, check its new `rust-toolchain.toml`,
`crates/honk-ebpf/rust-toolchain.toml`, `.github/ci/pins.env`
(`BPF_LINKER_VERSION`, `DOONA_VERSION`) and drop the version part of
`patches/honk-package-build-env.patch` if the package feed already defaults to
the wanted version.

## Troubleshooting

- **`honk` link step killed (OOM)** — lower `cargo_jobs` to `1`, or build on a
  runner with more RAM.
- **`the native-ui feature embeds doona`** — honk's `ci/fetch-doona.sh` could not
  download or verify the doona release; it fetches
  `Zakkaus/doona` `v0.1.0-rc.4` from GitHub and checks its SHA-256.
- **`no cargo in .../.cargo/bin`** — the Rust toolchains were installed for a
  different user than the one running the build; export `HONK_CARGO_HOME` or
  install them for the build user.
- **A `verify-config.sh` failure** — the seed config asked for a symbol the tree
  does not have (a renamed package, a dependency that is not met). The check
  prints which one; fix the seed rather than the check.
- **`verify-manifest.sh` reports `bridger`** — the filogic defaults were not
  patched; check that `prepare-tree.sh` reached the sed step.
