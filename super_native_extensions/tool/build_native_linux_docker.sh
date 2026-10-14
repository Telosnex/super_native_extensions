#!/usr/bin/env bash
# Local Linux build in the release containers, then the load smoke test.
#   tool/build_native_linux_docker.sh <linux-x64|linux-arm64|linux-riscv64>
# Output: build/native/out/<target>/. The release builds the same way, with
# `dart run native_prebuilt:build` (.github/workflows/native_release.yml).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-}"
case "$target" in
  linux-x64) image='debian:bullseye-slim@sha256:cba95a21c96c1f5fc2470081829363eed57706634f7dc26e8c6712934303d57a'; platform=linux/amd64 ;;
  linux-arm64) image='debian:bullseye-slim@sha256:cba95a21c96c1f5fc2470081829363eed57706634f7dc26e8c6712934303d57a'; platform=linux/arm64 ;;
  linux-riscv64) image='ubuntu:22.04@sha256:2edbbc5dc405e9612ba3584ce95480277e3eb374407b5505fe26f17df77c7dbc'; platform=linux/amd64 ;;
  *) echo "Usage: $0 <linux-x64|linux-arm64|linux-riscv64>" >&2; exit 64 ;;
esac
docker run --rm --platform "$platform" -v "$root/..:/repo" -w /repo/super_native_extensions \
  -e SNE_TARGET="$target" "$image" bash -lc '
    set -euo pipefail
    tool/install_linux_build_toolchain.sh "$SNE_TARGET"
    export PATH="$HOME/.cargo/bin:$PATH"
    git config --global --add safe.directory /repo
    [[ "$SNE_TARGET" != linux-riscv64 ]] || export SNE_SYSROOT=/opt/sne-sysroot
    tool/build_native_artifact.sh "$SNE_TARGET"
    tool/smoke_linux_library.sh "$SNE_TARGET" build/native/out/$SNE_TARGET/libsuper_native_extensions_native.so
  '
