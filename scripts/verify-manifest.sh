#!/usr/bin/env bash
#
# Check the built image: the firmware's package manifest has to contain the
# honk stack and must not contain the packages this build excludes. Also checks
# that the kernel really was built with the BTF options, because a successful
# build says nothing about them.
#
# usage: verify-manifest.sh <x86_64|gl-mt3000> <immortalwrt-dir>
#
set -euo pipefail

target=${1:?usage: verify-manifest.sh <x86_64|gl-mt3000> <immortalwrt-dir>}
openwrt_dir=${2:?usage: verify-manifest.sh <x86_64|gl-mt3000> <immortalwrt-dir>}

case "$target" in
x86_64) target_dir=$openwrt_dir/bin/targets/x86/64 ;;
gl-mt3000) target_dir=$openwrt_dir/bin/targets/mediatek/filogic ;;
*) echo "error: unknown target '$target'" >&2; exit 1 ;;
esac

[ -d "$target_dir" ] || { echo "error: $target_dir does not exist" >&2; exit 1; }

failures=0
checks=0
pass() { checks=$((checks + 1)); printf '  ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); printf '  FAIL %s\n' "$1"; }

# The firmware images are the ones with a manifest next to them.
mapfile -t manifests < <(find "$target_dir" -maxdepth 1 -name '*.manifest' | sort)
[ "${#manifests[@]}" -gt 0 ] ||
	{ echo "error: no *.manifest in $target_dir" >&2; exit 1; }
printf 'manifest: %s\n' "${manifests[@]}"

# With per-device rootfs an image has one manifest per device; the union of all
# lines is what matters here.
packages=$(cat "${manifests[@]}" | cut -d' ' -f1 | sort -u)

required="honk luci-app-honk luci-lib-daeuniverse luci-theme-vantage
luci-i18n-vantage-theme-zh-cn vmlinux-btf-builtin libstdcpp kmod-veth
kmod-sched-core kmod-sched-bpf kmod-nft-core kmod-nft-queue kmod-nfnetlink-queue
kmod-nf-conntrack v2ray-geoip v2ray-geosite nftables-json firewall4"

echo "== required packages in the image"
for package in $required; do
	if printf '%s\n' "$packages" | grep -qx "$package"; then
		pass "$package"
	else
		fail "$package is missing from the image"
	fi
done

if [ "$target" = "x86_64" ]; then
	echo "== x86/64 NIC drivers in the image"
	for package in kmod-e100 kmod-e1000 kmod-e1000e kmod-igb kmod-igbvf \
		kmod-igc kmod-r8169 kmod-vmxnet3 kmod-tg3 kmod-forcedeth \
		kmod-bnx2 kmod-ixgbe kmod-i40e
	do
		if printf '%s\n' "$packages" | grep -qx "$package"; then
			pass "$package"
		else
			fail "$package is missing from the image"
		fi
	done
fi

echo "== excluded packages"
for package in bridger ua3f golang; do
	if printf '%s\n' "$packages" | grep -qx "$package"; then
		fail "$package is in the image and must not be"
	else
		pass "$package is absent"
	fi
done

echo "== kernel was built with BTF"
kernel_config=$(find "$openwrt_dir/build_dir" -maxdepth 4 -path '*/linux-6.12.*/.config' 2>/dev/null | head -n1)
if [ -n "$kernel_config" ]; then
	for symbol in CONFIG_DEBUG_INFO_BTF=y CONFIG_DEBUG_INFO_BTF_MODULES=y; do
		if grep -qx "$symbol" "$kernel_config"; then
			pass "${symbol%%=*} in the kernel build config"
		else
			fail "${symbol%%=*} is missing from $kernel_config"
		fi
	done
else
	# Not fatal: the kernel config is pruned after the build in some versions.
	printf '  skip kernel build config not found under %s/build_dir\n' "$openwrt_dir"
fi

printf '\n%s checks, %s failed\n' "$checks" "$failures"
if [ "$failures" -ne 0 ]; then
	echo "error: the image does not match the specification" >&2
	exit 1
fi
