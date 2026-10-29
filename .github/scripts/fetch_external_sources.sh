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

# Failures surface as check annotations, which stay readable without a token.
fail() {
  local title=$1 detail=$2
  printf '::error title=%s::%s\n' "$title" \
    "$(printf '%s' "$detail" | tr '\n' '|' | tr -s '|' '|' | head -c 900)"
  printf '%s\n' "$detail" >&2
  exit 1
}

one_line() {
  printf '%s' "$1" | tr '\n' '|' | tr -s '|' '|' | head -c 400
}

if [ ! -f "$gitmodules" ]; then
  fail "Missing .gitmodules" "no $gitmodules"
fi

mapfile -t submodule_paths < <(
  git config --file "$gitmodules" --get-regexp '^submodule\..*\.path$' | awk '{print $2}'
)

if [ "${#submodule_paths[@]}" -eq 0 ]; then
  fail "No submodules declared" "$gitmodules lists no submodule entries"
fi

cd "$repo_root"

# Probe every upstream first: a network or auth failure is then reported as
# itself instead of as an opaque clone failure.
declare -A probe_errors=()
while read -r key url; do
  path=${key#submodule.}
  path=${path%.url}
  if probe_out=$(git ls-remote --heads "$url" 2>&1 >/dev/null); then
    printf 'reachable: %-70s\n' "$url"
  else
    probe_errors[$path]=$(one_line "${probe_out:-no output}")
    printf 'unreachable: %s\n  %s\n' "$url" "${probe_errors[$path]}"
  fi
done < <(git config --file "$gitmodules" --get-regexp '^submodule\..*\.url$')

if ! sync_out=$(git submodule sync --recursive 2>&1); then
  fail "git submodule sync failed" "$(one_line "$sync_out")"
fi

for path in "${submodule_paths[@]}"; do
  if [ -e "$repo_root/$path/.git" ]; then
    printf 'Submodule already initialized: %s\n' "$path"
    continue
  fi

  printf 'Fetching submodule %s (shallow)...\n' "$path"
  if pinned_out=$(git submodule update --init --depth 1 "$path" 2>&1); then
    printf 'Pinned revision available for %s\n' "$path"
    continue
  fi

  printf 'Pinned revision unavailable for %s, falling back to upstream head\n' "$path"
  if head_out=$(git submodule update --init --depth 1 --remote "$path" 2>&1); then
    continue
  fi

  rm -rf "${repo_root:?}/$path"
  fail "Submodule fetch failed: $path" \
    "probe: ${probe_errors[$path]:-ok} || pinned: $(one_line "$pinned_out") || head: $(one_line "$head_out")"
done

for path in "${submodule_paths[@]}"; do
  if [ ! -e "$repo_root/$path/.git" ]; then
    fail "Submodule not initialized: $path" "run git submodule update --init $path"
  fi
  printf '%-32s %s\n' "$path" "$(git -C "$repo_root/$path" rev-parse HEAD)"
done
