#!/usr/bin/env bash
# Materialize every external patch source declared in .gitmodules.
#
# The patch sources live in Git submodules so the repository stays the single
# place that defines where patches come from (and which revision they sit on).
# CI clones them shallowly from the upstream head, so a routine build always
# starts from the newest tree; the exact revision used for a release is then
# pinned by the caller (kernel tag for Debian, release tag for AmneziaWG) and
# recorded in build-manifest.json.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
gitmodules=$repo_root/.gitmodules

if [ ! -f "$gitmodules" ]; then
  printf 'error: .gitmodules not found in %s\n' "$repo_root" >&2
  exit 1
fi

mapfile -t submodule_paths < <(
  git config --file "$gitmodules" --get-regexp '^submodule\..*\.path$' | awk '{print $2}'
)

if [ "${#submodule_paths[@]}" -eq 0 ]; then
  printf 'error: no submodules declared in %s\n' "$gitmodules" >&2
  exit 1
fi

cd "$repo_root"
git submodule sync --recursive

for path in "${submodule_paths[@]}"; do
  if [ -e "$repo_root/$path/.git" ]; then
    printf 'Submodule already initialized: %s\n' "$path"
    continue
  fi
  printf 'Fetching submodule %s (shallow, upstream head)...\n' "$path"
  git submodule update --init --depth 1 --remote "$path"
done

for path in "${submodule_paths[@]}"; do
  if [ ! -e "$repo_root/$path/.git" ]; then
    printf 'error: submodule %s was not initialized\n' "$path" >&2
    exit 1
  fi
  printf '%-32s %s\n' "$path" "$(git -C "$repo_root/$path" rev-parse HEAD)"
done
