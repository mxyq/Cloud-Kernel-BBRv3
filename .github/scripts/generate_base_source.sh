#!/usr/bin/env bash
# Build the Debian base source tree for a kernel version: vanilla kernel.org
# sources with Debian's kernel-team patch series applied. The result is frozen
# as a release asset, so builds never re-apply the Debian patch series
# themselves -- they only layer XanMod and project patches on top of it.
set -euo pipefail

usage() {
  printf 'usage: %s <kernel-version> <work-dir> <output-file>\n' "$(basename "$0")" >&2
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
  printf 'error: work path already exists: %s\n' "$tree_dir" >&2
  exit 1
fi

# --- vanilla sources from kernel.org, sha256 verified ---
printf 'Downloading Linux %s source...\n' "$kernel_version"
curl --fail --location --retry 3 \
  --output "$work_dir/linux-$kernel_version.tar.xz" \
  "https://cdn.kernel.org/pub/linux/kernel/v${kernel_major}.x/linux-${kernel_version}.tar.xz"
expected=$(curl --fail --location --retry 3 --silent \
  "https://cdn.kernel.org/pub/linux/kernel/v${kernel_major}.x/sha256sums.asc" \
  | sed -n "s/^\\([0-9a-f]\\{64\\}\\)  linux-$kernel_version\\.tar\\.xz$/\\1/p")
if [ -z "$expected" ]; then
  printf 'error: sha256 for linux-%s.tar.xz not found\n' "$kernel_version" >&2
  exit 1
fi
actual=$(sha256sum "$work_dir/linux-$kernel_version.tar.xz" | cut -d' ' -f1)
if [ "$actual" != "$expected" ]; then
  printf 'error: vanilla source sha256 mismatch (%s != %s)\n' "$actual" "$expected" >&2
  exit 1
fi
tar -xJf "$work_dir/linux-$kernel_version.tar.xz" -C "$work_dir"
mv "$work_dir/linux-$kernel_version" "$tree_dir"
rm -f "$work_dir/linux-$kernel_version.tar.xz"

# --- Debian patch series, pinned to the release tag ---
if [ ! -e "$debian_dir/.git" ]; then
  printf 'error: submodule vendor/linux-debian is not initialized\n' >&2
  exit 1
fi
git -C "$debian_dir" fetch --depth=1 origin "refs/tags/debian/$kernel_version-1"
git -C "$debian_dir" checkout --detach --force FETCH_HEAD

cp -R "$debian_dir/debian/patches" "$tree_dir/patches"

printf 'Applying Debian patch series (%s patches)...\n' \
  "$(grep -cE '^[a-zA-Z0-9]' "$tree_dir/patches/series")"
(
  cd "$tree_dir"
  QUILT_PATCHES=patches quilt push -a
)

# The applied result is what gets frozen. Quilt bookkeeping and the patch
# files themselves are dropped: the frozen tree already contains their effect,
# and builds layer their own patch series on top of it.
rm -rf "$tree_dir/.pc" "$tree_dir/patches"

# debian/ travels inside the base tarball: apply_config.sh reads the kernel
# configs from it, so builds do not need the Debian submodule at all.
cp -R "$debian_dir/debian" "$tree_dir/debian"

# --- pack ---
mkdir -p "$(dirname -- "$output_file")"
tar -cJf "$output_file" -C "$work_dir" "linux-$kernel_version"
sha256sum "$output_file" | tee "$output_file.sha256"
printf 'Base source written: %s (%s)\n' \
  "$output_file" "$(du -h "$output_file" | cut -f1)"
