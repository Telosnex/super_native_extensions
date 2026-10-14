#!/usr/bin/env bash
# Loads a built Linux library on its target ABI (QEMU for riscv64): checks
# the real dynamic dependencies, not only the ELF headers.
#   tool/smoke_linux_library.sh <target> <library>
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
target="$1"; binary="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
case "$target" in
  linux-x64|linux-arm64)
    cc "$root/tool/smoke_native_library.c" -ldl -o /tmp/sne-smoke
    /tmp/sne-smoke "$binary"
    ;;
  linux-riscv64)
    riscv64-linux-gnu-gcc --sysroot=/opt/sne-sysroot "$root/tool/smoke_native_library.c" -ldl -o /tmp/sne-smoke
    qemu-riscv64 -L /opt/sne-sysroot /tmp/sne-smoke "$binary"
    ;;
  *) echo "Usage: $0 <linux-x64|linux-arm64|linux-riscv64> <library>" >&2; exit 64 ;;
esac
# glibc baseline of the release (see native_artifacts/README.md).
newest="$(objdump -T "$binary" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
echo "Newest glibc requirement: $newest"
case "$target" in
  linux-riscv64) limit=GLIBC_2.35 ;;
  *) limit=GLIBC_2.31 ;;
esac
test "$(printf '%s\n' "$limit" "$newest" | sort -V | tail -1)" = "$limit"
