#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-}"
mode="${2:-build}"
case "$mode" in build|verify) ;; *) echo "Mode must be build or verify" >&2; exit 64 ;; esac
case "$target" in
  linux-x64|linux-arm64) image='debian:bullseye-slim@sha256:cba95a21c96c1f5fc2470081829363eed57706634f7dc26e8c6712934303d57a' ;;
  linux-riscv64) image='ubuntu:22.04@sha256:2edbbc5dc405e9612ba3584ce95480277e3eb374407b5505fe26f17df77c7dbc' ;;
  *) echo "Usage: $0 <linux-x64|linux-arm64|linux-riscv64>" >&2; exit 64 ;;
esac
# Build with a native x64 compiler and a target GTK sysroot; no emulated Rust.
docker run --rm --platform linux/amd64 -v "$root/..:/repo" -w /repo/super_native_extensions \
  -e SNE_TARGET="$target" -e SNE_MODE="$mode" -e SNE_BUILD_IMAGE="$image" "$image" bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    if [[ "$SNE_TARGET" != linux-riscv64 ]]; then
      # Immutable package indexes: bullseye security packages disappear from
      # rolling mirrors after superseding updates.
      printf "%s\n" \
        "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260801T000000Z bullseye main" \
        "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260801T000000Z bullseye-security main" \
        > /etc/apt/sources.list
    fi
    case "$SNE_TARGET" in
      linux-x64) arch=amd64; cross=x86_64-linux-gnu ;;
      linux-arm64) arch=arm64; cross=aarch64-linux-gnu; dpkg --add-architecture arm64 ;;
      linux-riscv64)
        arch=riscv64; cross=riscv64-linux-gnu
        dpkg --add-architecture riscv64
        sed -i "s/^deb /deb [arch=amd64] /" /etc/apt/sources.list
        printf "%s\n" "deb [arch=riscv64] http://ports.ubuntu.com/ubuntu-ports jammy main universe" "deb [arch=riscv64] http://ports.ubuntu.com/ubuntu-ports jammy-updates main universe" "deb [arch=riscv64] http://ports.ubuntu.com/ubuntu-ports jammy-security main universe" > /etc/apt/sources.list.d/riscv64.list
        ;;
    esac
    compiler="gcc-$cross"
    [[ "$arch" != amd64 ]] || compiler=gcc
    apt-get update -qq
    apt-get install -y --no-install-recommends ca-certificates curl git python3 build-essential pkg-config "$compiler"
    if [[ "$arch" == riscv64 ]]; then
      # Jammy riscv64 security updates lag amd64; a separate sysroot avoids
      # incompatible Multi-Arch:same package version requirements on the host.
      mkdir -p /tmp/target-debs/partial /opt/sne-sysroot
      apt-get -o APT::Architecture=riscv64 -o Dir::State::status=/dev/null \
        -o Dir::Cache::archives=/tmp/target-debs install --download-only -y \
        --no-install-recommends libgtk-3-dev:riscv64
      for deb in /tmp/target-debs/*.deb; do dpkg-deb -x "$deb" /opt/sne-sysroot; done
      export SNE_SYSROOT=/opt/sne-sysroot
    else
      apt-get install -y --no-install-recommends "libgtk-3-dev:$arch"
    fi
    if [[ "$SNE_MODE" == build ]]; then
      curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
      export PATH="$HOME/.cargo/bin:$PATH"
      git config --global --add safe.directory /repo
      tool/build_native_artifact.sh "$SNE_TARGET"
    fi
    # Validate actual dynamic dependencies on the target ABI, not just ELF
    # headers. QEMU is only used by maintainers/CI, never by consumer hooks.
    apt-get install -y --no-install-recommends qemu-user
    "$cross-gcc" ${SNE_SYSROOT:+--sysroot="$SNE_SYSROOT"} tool/smoke_native_library.c -ldl -o /tmp/sne-smoke
    binary="$(pwd)/native_artifacts/$SNE_TARGET/libsuper_native_extensions_native.so"
    case "$arch" in
      amd64) /tmp/sne-smoke "$binary" ;;
      arm64) qemu-aarch64 -L /usr/aarch64-linux-gnu /tmp/sne-smoke "$binary" ;;
      riscv64) qemu-riscv64 -L "$SNE_SYSROOT" /tmp/sne-smoke "$binary" ;;
    esac
  '
