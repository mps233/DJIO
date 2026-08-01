#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
helper_root="$project_root/Packaging/Helpers/lpac"
patch_path="$helper_root/patches/0001-djio-stdio-and-secret-input.patch"
expected_commit="c2fcf5e4b21c712d54e35a11da2ad9ad134fb821"

if ! command -v gh >/dev/null; then
  echo "需要 GitHub CLI（gh）来获取 lpac v2.3.0 源码" >&2
  exit 1
fi

cmake_bin="$(command -v cmake 2>/dev/null || true)"
if [[ -z "$cmake_bin" && -x "$(brew --prefix cmake 2>/dev/null)/bin/cmake" ]]; then
  cmake_bin="$(brew --prefix cmake)/bin/cmake"
fi
if [[ -z "$cmake_bin" ]]; then
  echo "需要 CMake：brew install cmake" >&2
  exit 1
fi

source_root="$(mktemp -d "${TMPDIR:-/tmp}/djio-lpac-source.XXXXXX")"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/djio-lpac-build.XXXXXX")"
trap '/bin/rm -rf -- "$source_root" "$build_root"' EXIT

/bin/rmdir "$source_root" "$build_root"
gh repo clone estkme-group/lpac "$source_root" -- --branch v2.3.0 --depth 1

actual_commit="$(git -C "$source_root" rev-parse HEAD)"
if [[ "$actual_commit" != "$expected_commit" ]]; then
  echo "lpac v2.3.0 commit 不匹配：$actual_commit" >&2
  exit 1
fi

git -C "$source_root" apply --check "$patch_path"
git -C "$source_root" apply "$patch_path"

"$cmake_bin" \
  -S "$source_root" \
  -B "$build_root" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
"$cmake_bin" --build "$build_root" --parallel

/bin/cp "$build_root/output/lpac" "$helper_root/lpac"
/bin/chmod 755 "$helper_root/lpac"

"$helper_root/lpac" version
/usr/bin/shasum -a 256 "$helper_root/lpac"
