#!/usr/bin/env bash
# Installs the Linux build toolchain in a pinned container: GCC, pkg-config,
# GTK 3 headers for the target, rustup, and QEMU for the load smoke test.
# Used by tool/build_native_linux_docker.sh and the native release workflow.
#
#   tool/install_linux_build_toolchain.sh <linux-x64|linux-arm64|linux-riscv64>
#
# linux-x64 and linux-arm64 build natively in debian:bullseye (glibc 2.31),
# from an immutable snapshot: bullseye security packages disappear from
# rolling mirrors. linux-riscv64 cross-compiles in ubuntu:22.04 against a
# target sysroot in /opt/sne-sysroot.
set -euo pipefail
target="${1:-}"
export DEBIAN_FRONTEND=noninteractive
# snapshot.debian.org often returns 503 under load.
echo 'Acquire::Retries "8";' > /etc/apt/apt.conf.d/80-retries
case "$target" in
  linux-x64|linux-arm64)
    printf "%s\n" \
      "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260801T000000Z bullseye main" \
      "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260801T000000Z bullseye-security main" \
      > /etc/apt/sources.list
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates curl git \
      python3 build-essential pkg-config libgtk-3-dev qemu-user unzip > /dev/null
    ;;
  linux-riscv64)
    dpkg --add-architecture riscv64
    sed -i "s/^deb /deb [arch=amd64] /" /etc/apt/sources.list
    printf "%s\n" \
      "deb [arch=riscv64] http://ports.ubuntu.com/ubuntu-ports jammy main universe" \
      "deb [arch=riscv64] http://ports.ubuntu.com/ubuntu-ports jammy-updates main universe" \
      "deb [arch=riscv64] http://ports.ubuntu.com/ubuntu-ports jammy-security main universe" \
      > /etc/apt/sources.list.d/riscv64.list
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates curl git \
      python3 build-essential pkg-config gcc-riscv64-linux-gnu qemu-user unzip > /dev/null
    # Jammy riscv64 security updates lag amd64; a separate sysroot avoids
    # incompatible Multi-Arch:same package version requirements on the host.
    mkdir -p /tmp/target-debs/partial /opt/sne-sysroot
    apt-get -o APT::Architecture=riscv64 -o Dir::State::status=/dev/null \
      -o Dir::Cache::archives=/tmp/target-debs install --download-only -y -qq \
      --no-install-recommends libgtk-3-dev:riscv64 > /dev/null
    for deb in /tmp/target-debs/*.deb; do dpkg-deb -x "$deb" /opt/sne-sysroot; done
    ;;
  *) echo "Usage: $0 <linux-x64|linux-arm64|linux-riscv64>" >&2; exit 64 ;;
esac
curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --default-toolchain none
