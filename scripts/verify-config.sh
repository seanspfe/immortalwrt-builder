#!/usr/bin/env bash
#
# Verify that the .config produced by `make defconfig` really carries what this
# build is supposed to contain. A seed config can be silently pruned by
# defconfig (a symbol that no longer exists, a dependency that is not met), and
# the build would still succeed with the wrong image, so every requirement is
# checked here instead of being trusted.
#
# usage: verify-config.sh <x86_64|gl-mt3000> <immortalwrt-dir>
#
set -euo pipefail

config_name=${1:?usage: verify-config.sh <x86_64|gl-mt3000> <immortalwrt-dir>}
openwrt_dir=${2:?usage: verify-config.sh <x86_64|gl-mt3000> <immortalwrt-dir>}
config=$openwrt_dir/.config

[ -r "$config" ] || { echo "error: $config is missing; run make defconfig first" >&2; exit 1; }

failures=0
checks=0

pass() { checks=$((checks + 1)); printf '  ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); printf '  FAIL %s\n' "$1"; }

# require_y SYMBOL - the symbol has to be enabled
require_y() {
	if grep -qx "CONFIG_$1=y" "$config"; then
		pass "$1=y"
	else
		fail "$1=y (not enabled in .config)"
	fi
}

# require_not_set SYMBOL - the symbol has to be off, explicitly or by absence
require_not_set() {
	if grep -qx "# CONFIG_$1 is not set" "$config"; then
		pass "$1 is not set"
	elif grep -qx "CONFIG_$1=y" "$config"; then
		fail "$1 must not be enabled"
	else
		pass "$1 is not set"
	fi
}

echo "== honk and its LuCI front end"
for symbol in \
	PACKAGE_honk \
	PACKAGE_luci-app-honk \
	PACKAGE_luci-lib-daeuniverse \
	PACKAGE_vmlinux-btf-builtin \
	PACKAGE_luci-theme-vantage \
	PACKAGE_luci-i18n-vantage-theme-zh-cn
do
	require_y "$symbol"
done

echo "== honk runtime dependencies"
for symbol in \
	PACKAGE_libstdcpp \
	PACKAGE_kmod-veth \
	PACKAGE_kmod-sched-core \
	PACKAGE_kmod-sched-bpf \
	PACKAGE_kmod-nft-core \
	PACKAGE_kmod-nft-queue \
	PACKAGE_kmod-nfnetlink-queue \
	PACKAGE_kmod-nf-conntrack \
	PACKAGE_v2ray-geoip \
	PACKAGE_v2ray-geosite \
	PACKAGE_nftables-json \
	PACKAGE_firewall4
do
	require_y "$symbol"
done

echo "== kernel BTF for eBPF CO-RE"
require_y KERNEL_DEBUG_INFO_BTF
require_y KERNEL_DEBUG_INFO_BTF_MODULES
require_not_set KERNEL_DEBUG_INFO_REDUCED
# KERNEL_DEBUG_INFO has `default y if !SMALL_FLASH`; only an explicit "is not
# set" means the BTF choice lost its dependency.
if grep -qx '# CONFIG_KERNEL_DEBUG_INFO is not set' "$config"; then
	fail "KERNEL_DEBUG_INFO is not set; BTF cannot be generated"
else
	pass "KERNEL_DEBUG_INFO is enabled"
fi

echo "== excluded packages"
require_not_set PACKAGE_ua3f
require_not_set PACKAGE_bridger
require_not_set PACKAGE_golang

case "$config_name" in
x86_64)
	echo "== x86/64 target and image format"
	require_y TARGET_x86
	require_y TARGET_x86_64
	require_y TARGET_DEVICE_x86_64_DEVICE_generic
	require_y TARGET_ROOTFS_SQUASHFS
	require_y GRUB_EFI_IMAGES
	require_y TARGET_IMAGES_GZIP

	echo "== wired NIC drivers"
	for symbol in \
		PACKAGE_kmod-e100 PACKAGE_kmod-e1000 PACKAGE_kmod-e1000e \
		PACKAGE_kmod-igb PACKAGE_kmod-igbvf PACKAGE_kmod-igc \
		PACKAGE_kmod-r8169 PACKAGE_kmod-vmxnet3 PACKAGE_kmod-tg3 \
		PACKAGE_kmod-forcedeth PACKAGE_kmod-bnx2 PACKAGE_kmod-ixgbe \
		PACKAGE_kmod-i40e
	do
		require_y "$symbol"
	done

	# virtio_net / virtio_pci are built into this target's kernel; there are no
	# kmod packages for them, so the drivers are checked in the kernel config.
	echo "== virtual NIC drivers (built in, not modules)"
	for symbol in CONFIG_VIRTIO_NET=y CONFIG_VIRTIO_PCI=y; do
		if grep -qx "$symbol" "$openwrt_dir/target/linux/x86/64/config-6.12"; then
			pass "${symbol%%=*} built into the x86/64 kernel"
		else
			fail "${symbol%%=*} is missing from target/linux/x86/64/config-6.12"
		fi
	done
	;;
gl-mt3000)
	echo "== mediatek/filogic target and GL-MT3000 device"
	require_y TARGET_mediatek
	require_y TARGET_mediatek_filogic
	require_y TARGET_DEVICE_mediatek_filogic_DEVICE_glinet_gl-mt3000

	echo "== GL-MT3000 radios, USB and storage"
	for symbol in \
		PACKAGE_kmod-mt7915e PACKAGE_kmod-mt7981-firmware \
		PACKAGE_mt7981-wo-firmware PACKAGE_kmod-hwmon-pwmfan \
		PACKAGE_kmod-usb3 PACKAGE_automount
	do
		require_y "$symbol"
	done

	echo "== bridger stays out of the filogic defaults"
	if grep -qw bridger "$openwrt_dir/target/linux/mediatek/filogic/target.mk"; then
		fail "bridger is still in target/linux/mediatek/filogic/target.mk"
	else
		pass "bridger removed from DEFAULT_PACKAGES"
	fi
	;;
*)
	echo "error: unknown config '$config_name'" >&2
	exit 1
	;;
esac

printf '\n%s checks, %s failed\n' "$checks" "$failures"
if [ "$failures" -ne 0 ]; then
	echo "error: the resolved config does not match the specification" >&2
	exit 1
fi
