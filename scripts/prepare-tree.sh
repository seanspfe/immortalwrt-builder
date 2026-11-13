#!/usr/bin/env bash
#
# Prepare the ImmortalWrt build tree for one target:
#
#   * check out ImmortalWrt, daeuniverse/openwrt-packages, the Vantage theme and
#     honk at the commits pinned in README.md (every pin can be overridden from
#     the environment),
#   * put honk's sources where its package Makefile expects them (honk/src),
#   * apply the packaging patches: the honk build environment and the removal of
#     `bridger` from the filogic target's default packages,
#   * wire both external feeds into feeds.conf.default and install all feeds.
#
# Run from anywhere; paths are resolved from this script's location.
#
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src_root=${SRC_ROOT:-$repo_root/.src}
openwrt_dir=${OPENWRT_DIR:-$src_root/immortalwrt}
feeds_dir=${FEEDS_DIR:-$src_root/feeds}
packages_dir=$feeds_dir/openwrt-packages
vantage_dir=$feeds_dir/luci-theme-vantage

# Pins. The commits are what the tags resolve to; each checkout is verified
# against them, so a moved tag fails the build instead of silently drifting.
: "${IMMORTALWRT_REPO:=https://github.com/immortalwrt/immortalwrt.git}"
: "${IMMORTALWRT_TAG:=v25.12.2}"
: "${IMMORTALWRT_COMMIT:=4fc16f2985a358bd43bb522e43f05395fcbd6ed5}"
: "${IMMORTALWRT_KERNEL:=6.12.103}"
: "${PACKAGES_REPO:=https://github.com/daeuniverse/openwrt-packages.git}"
: "${PACKAGES_COMMIT:=e48b222f239e2572244c8cf495fbce79b0da7528}"
: "${VANTAGE_REPO:=https://github.com/anothaDev/luci-theme-vantage.git}"
: "${VANTAGE_TAG:=v1.0.14}"
: "${VANTAGE_COMMIT:=cddbfb262b7a67a0d3762039e4af66fc0ac92000}"
: "${HONK_REPO:=https://github.com/daeuniverse/honk.git}"
: "${HONK_TAG:=v0.1.0-beta.4}"
: "${HONK_COMMIT:=d3fb81f4d7155581f9d276936690dc9f60ef2b77}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_commit() {
	local dir=$1 expected=$2 name=$3 got
	got=$(git -C "$dir" rev-parse HEAD)
	[ "$got" = "$expected" ] || die "$name: HEAD is $got, expected $expected"
	printf '%s @ %s\n' "$name" "$got"
}

# clone_tag URL TAG DIR COMMIT NAME - shallow checkout of a tag, verified by commit.
# An existing checkout is reused: the tag is fetched again and checked out, so a
# second run moves the tree to the pin instead of needing a fresh clone.
clone_tag() {
	local url=$1 tag=$2 dir=$3 commit=$4 name=$5
	if [ -d "$dir/.git" ]; then
		git -C "$dir" fetch --quiet --depth 1 --force origin \
			"refs/tags/$tag:refs/tags/$tag"
		git -C "$dir" checkout --quiet --detach "refs/tags/$tag"
	else
		mkdir -p "$(dirname "$dir")"
		git clone --quiet --depth 1 --single-branch --branch "$tag" "$url" "$dir"
	fi
	require_commit "$dir" "$commit" "$name"
}

# clone_commit URL COMMIT DIR NAME - shallow checkout of a bare commit
clone_commit() {
	local url=$1 commit=$2 dir=$3 name=$4
	if [ ! -d "$dir/.git" ]; then
		mkdir -p "$dir"
		git -C "$dir" init --quiet
		git -C "$dir" remote add origin "$url"
	else
		git -C "$dir" remote set-url origin "$url"
	fi
	git -C "$dir" fetch --quiet --depth 1 --force origin "$commit"
	git -C "$dir" checkout --quiet --detach FETCH_HEAD
	require_commit "$dir" "$commit" "$name"
}

log "ImmortalWrt $IMMORTALWRT_TAG"
clone_tag "$IMMORTALWRT_REPO" "$IMMORTALWRT_TAG" "$openwrt_dir" \
	"$IMMORTALWRT_COMMIT" immortalwrt

kernel_version=$(sed -n 's/^LINUX_VERSION-6\.12 = \.//p' \
	"$openwrt_dir/target/linux/generic/kernel-6.12")
[ "$kernel_version" = "${IMMORTALWRT_KERNEL#6.12.}" ] ||
	die "kernel is 6.12.$kernel_version, expected $IMMORTALWRT_KERNEL"
printf 'kernel 6.12.%s\n' "$kernel_version"

log "daeuniverse/openwrt-packages @ $PACKAGES_COMMIT"
clone_commit "$PACKAGES_REPO" "$PACKAGES_COMMIT" "$packages_dir" openwrt-packages

log "Vantage theme $VANTAGE_TAG"
clone_tag "$VANTAGE_REPO" "$VANTAGE_TAG" "$vantage_dir" "$VANTAGE_COMMIT" \
	luci-theme-vantage

log "honk $HONK_TAG into the package's src/"
honk_src=$packages_dir/honk/src
clone_tag "$HONK_REPO" "$HONK_TAG" "$honk_src" "$HONK_COMMIT" honk
# The package copies this tree into its build directory; the checkout metadata
# only costs space and build time.
if ! rm -rf "$honk_src/.git" 2>/dev/null; then
	echo "warning: could not remove $honk_src/.git; the build will copy it too"
fi

log "Applying packaging patches"
honk_patch=$repo_root/patches/honk-package-build-env.patch
if git -C "$packages_dir" apply --reverse --check "$honk_patch" 2>/dev/null; then
	echo "honk package patch already applied"
else
	git -C "$packages_dir" apply "$honk_patch"
	echo "honk package patch applied"
fi

# Ensure build.sh parameter checks do not fail on full buildroots
sed -E -i 's/\$\{HONK_ARCH_PACKAGES:\?HONK_ARCH_PACKAGES is not set\}/\$\{HONK_ARCH_PACKAGES:-\$\{ARCH:-x86_64\}\}/g' "$packages_dir/honk/build.sh"
sed -E -i 's/\$\{OPENWRT_CC:\?OPENWRT_CC is not set\}/\$\{OPENWRT_CC:-\$\{TARGET_CROSS\}gcc\}/g' "$packages_dir/honk/build.sh"
sed -E -i 's/\$\{OPENWRT_CXX:\?OPENWRT_CXX is not set\}/\$\{OPENWRT_CXX:-\$\{TARGET_CROSS\}g\+\+\}/g' "$packages_dir/honk/build.sh"

# Enable execution trace in honk build.sh
if ! grep -q 'set -x' "$packages_dir/honk/build.sh"; then
	sed -i '2i set -x' "$packages_dir/honk/build.sh"
fi

# Unsilence OpenWrt package compilation so any sub-make errors are printed
if [ -f "$openwrt_dir/include/verbose.mk" ]; then
	sed -i -E 's/SILENT:=>\/dev\/null.*/SILENT:=/' "$openwrt_dir/include/verbose.mk"
fi

# ImmortalWrt's filogic target adds bridger to DEFAULT_PACKAGES, so a plain
# GL-MT3000 build would ship it. This build excludes bridger, and the exclusion
# lives in the target's default list, which is a make variable rather than a
# Kconfig symbol: `CONFIG_PACKAGE_bridger is not set` would not remove it.
filogic_target=$openwrt_dir/target/linux/mediatek/filogic/target.mk
if grep -qw bridger "$filogic_target"; then
	sed -i -E 's/[[:space:]]*bridger([[:space:]]|$)/\1/' "$filogic_target"
	echo "bridger removed from the filogic default packages"
fi
if grep -qw bridger "$filogic_target"; then
	die "bridger is still in $filogic_target"
fi

log "Wiring the external feeds"
feeds_conf=$openwrt_dir/feeds.conf.default
grep -q '^src-link openwrt_packages ' "$feeds_conf" ||
	printf 'src-link openwrt_packages %s\n' "$packages_dir" >>"$feeds_conf"
grep -q '^src-link luci_vantage ' "$feeds_conf" ||
	printf 'src-link luci_vantage %s\n' "$vantage_dir" >>"$feeds_conf"

log "Updating and installing feeds"
(
	cd "$openwrt_dir"
	./scripts/feeds update -a
	./scripts/feeds install -a
)

# The feeds are symlinked, so the honk sources have to be visible through the
# installed package directory as well.
installed_honk=$openwrt_dir/package/feeds/openwrt_packages/honk
[ -r "$installed_honk/Makefile" ] ||
	die "the honk package is not installed at $installed_honk"
[ -r "$installed_honk/src/Cargo.toml" ] ||
	die "honk sources are missing at $installed_honk/src"
grep -q 'CARGO_PROFILE_RELEASE_LTO=false' "$installed_honk/Makefile" ||
	die "the honk package patch is not in place at $installed_honk/Makefile"
grep -q 'HONK_TARGET_ARCH' "$installed_honk/Makefile" ||
	die "the honk package patch is missing HONK_TARGET_ARCH at $installed_honk/Makefile"

log "Build tree ready: $openwrt_dir"
