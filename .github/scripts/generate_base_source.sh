#!/usr/bin/env bash
# Build the Debian base source tree for a kernel version: vanilla kernel.org
# sources with Debian's kernel-team patch series applied. The result is frozen
# as a release asset, so builds never re-apply the Debian patch series
# themselves -- they only layer XanMod and project patches on top of it.
set -euo pipefail

usage() {
  printf '::error::usage: %s <kernel-version> <work-dir> <output-file>\n' "$(basename "$0")" >&2
  exit 1
}

fail() {
  printf '::error::error: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 3 ] || usage

kernel_version=$1
work_dir=$(realpath -m "$2")
output_file=$3

series=${kernel_version%.*}
kernel_major=${kernel_version%%.*}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
debian_dir=$repo_root/vendor/linux-debian

mkdir -p "$work_dir"
tree_dir=$work_dir/linux-$kernel_version
if [ -e "$tree_dir" ]; then
  fail "work path already exists: $tree_dir"
fi

curl_opts=(--fail --location --show-error --connect-timeout 30 --retry 5 --retry-delay 5)

# --- vanilla sources from kernel.org, sha256 verified ---
printf 'Downloading Linux %s source from kernel.org...\n' "$kernel_version"
if ! curl "${curl_opts[@]}" \
  --output "$work_dir/linux-$kernel_version.tar.xz" \
  "https://cdn.kernel.org/pub/linux/kernel/v${kernel_major}.x/linux-${kernel_version}.tar.xz"; then
  fail "vanilla source download failed (linux-$kernel_version.tar.xz)"
fi

printf 'Verifying vanilla source sha256...\n'
expected=$(curl "${curl_opts[@]}" \
  "https://cdn.kernel.org/pub/linux/kernel/v${kernel_major}.x/sha256sums.asc" \
  | sed -n "s/^\\([0-9a-f]\\{64\\}\\)  linux-$kernel_version\\.tar\\.xz$/\\1/p" || true)
[ -n "$expected" ] || fail "sha256 for linux-$kernel_version.tar.xz not found in the kernel.org manifest"

actual=$(sha256sum "$work_dir/linux-$kernel_version.tar.xz" | cut -d' ' -f1)
[ "$actual" = "$expected" ] || fail "vanilla source sha256 mismatch ($actual != $expected)"

printf 'Extracting...\n'
if ! tar -xJf "$work_dir/linux-$kernel_version.tar.xz" -C "$work_dir"; then
  fail "failed to extract linux-$kernel_version.tar.xz"
fi
# The tarball already unpacks to $work_dir/linux-<version>, which is exactly
# $tree_dir -- moving it "into place" would mean moving it into itself.
[ -d "$tree_dir" ] || fail "unexpected tarball layout: $tree_dir missing after extraction"
rm -f "$work_dir/linux-$kernel_version.tar.xz"

# --- Debian patch series, pinned to the release tag ---
[ -e "$debian_dir/.git" ] || fail "submodule vendor/linux-debian is not initialized"
if ! git -C "$debian_dir" fetch --depth=1 origin "refs/tags/debian/$kernel_version-1"; then
  fail "Debian tag debian/$kernel_version-1 not found in vendor/linux-debian"
fi
git -C "$debian_dir" checkout --detach --force FETCH_HEAD

cp -R "$debian_dir/debian/patches" "$tree_dir/patches"

patch_count=$(grep -cE '^[a-zA-Z0-9]' "$tree_dir/patches/series" || true)
printf 'Applying Debian patch series (%s patches)...\n' "$patch_count"
if ! ( cd "$tree_dir" && QUILT_PATCHES=patches quilt push -a ); then
  fail "Debian patch series failed to apply ($patch_count patches)"
fi

# The applied result is what gets frozen. Quilt bookkeeping and the patch files
# themselves are dropped: the frozen tree already contains their effect, and
# builds layer their own patch series on top of it.
rm -rf "$tree_dir/.pc" "$tree_dir/patches"

# debian/ travels inside the base tarball: apply_config.sh reads the kernel
# configs from it, so builds do not need the Debian submodule at all.
cp -R "$debian_dir/debian" "$tree_dir/debian"

# --- pack ---
mkdir -p "$(dirname -- "$output_file")"
printf 'Packing base source...\n'
if ! tar -cJf "$output_file" -C "$work_dir" "linux-$kernel_version"; then
  fail "failed to pack the base source tarball"
fi
sha256sum "$output_file" | tee "$output_file.sha256"
printf 'Base source written: %s (%s)\n' \
  "$output_file" "$(du -h "$output_file" | cut -f1)"
