#!/usr/bin/env bash
# Builds the native library for one target with Cargo.
#
# hook/build.dart runs it for source builds (native_prebuilt ADR 001), and so
# does the release workflow, through `dart run native_prebuilt:build`.
# Environment:
#   SNE_OUTPUT              Write the library here. Default:
#                           build/native/out/<target>/.
#   SNE_CARGO_TARGET_DIR    Cargo target directory.
#   SNE_RUST_TOOLCHAIN      "host": use the cargo on PATH, no rustup. For
#                           builds without network (Flatpak): Cargo's config
#                           in $HOME/.cargo must vendor the crates.
#   SNE_SYSROOT             Target sysroot for a cross build (riscv64).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-}"
rust=1.97.1
name=super_native_extensions_native
export CARGO_TARGET_DIR="${SNE_CARGO_TARGET_DIR:-$root/build/native/cargo}"
export CARGO_INCREMENTAL=0
export MACOSX_DEPLOYMENT_TARGET=12.0
export IPHONEOS_DEPLOYMENT_TARGET=13.0
export CARGO_PROFILE_RELEASE_STRIP=symbols
case "$target" in
  macos-arm64) triple=aarch64-apple-darwin ;;
  macos-x64) triple=x86_64-apple-darwin ;;
  ios-arm64-iphoneos) triple=aarch64-apple-ios ;;
  ios-arm64-iphonesimulator) triple=aarch64-apple-ios-sim; export IPHONEOS_DEPLOYMENT_TARGET=14.0 ;;
  ios-x64-iphonesimulator) triple=x86_64-apple-ios ;;
  android-arm) triple=armv7-linux-androideabi; ndk_triple=armv7a-linux-androideabi ;;
  android-arm64) triple=aarch64-linux-android; ndk_triple=$triple ;;
  android-x64) triple=x86_64-linux-android; ndk_triple=$triple ;;
  linux-x64) triple=x86_64-unknown-linux-gnu; cross=x86_64-linux-gnu ;;
  linux-arm64) triple=aarch64-unknown-linux-gnu; cross=aarch64-linux-gnu ;;
  linux-riscv64) triple=riscv64gc-unknown-linux-gnu; cross=riscv64-linux-gnu ;;
  windows-x64) triple=x86_64-pc-windows-msvc ;;
  windows-arm64) triple=aarch64-pc-windows-msvc ;;
  *) echo "Usage: $0 <macos-{arm64,x64}|ios-arm64-{iphoneos,iphonesimulator}|ios-x64-iphonesimulator|android-{arm,arm64,x64}|linux-{arm64,x64,riscv64}|windows-{arm64,x64}>" >&2; exit 64 ;;
esac
if [[ "${SNE_RUST_TOOLCHAIN:-}" == host ]]; then
  cargo=(cargo)
else
  # Avoid rust-toolchain.toml installing every cross target on each build host.
  rustup toolchain install "$rust" --profile minimal --no-self-update
  rustup target add --toolchain "$rust" "$triple"
  cargo=(cargo +"$rust")
fi
key="$(echo "$triple" | tr '[:lower:]-' '[:upper:]_')"
case "$target" in
  macos-*|ios-*)
    output="lib$name.dylib"
    export "CARGO_TARGET_${key}_RUSTFLAGS=-C link-arg=-Wl,-install_name,@rpath/$output -C link-arg=-Wl,-headerpad_max_install_names"
    ;;
  android-*)
    ndk="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
    grep -q 'Pkg.Revision = 28.2.13676358' "$ndk/source.properties"
    case "$(uname -s)" in Darwin) host=darwin-x86_64 ;; Linux) host=linux-x86_64 ;; *) exit 1 ;; esac
    bin="$ndk/toolchains/llvm/prebuilt/$host/bin"
    export "CARGO_TARGET_${key}_LINKER=$bin/${ndk_triple}24-clang"
    export "CC_${triple//-/_}=$bin/${ndk_triple}24-clang"
    export "AR_${triple//-/_}=$bin/llvm-ar"
    export "CARGO_TARGET_${key}_RUSTFLAGS=-C link-arg=-Wl,-soname,lib$name.so -C link-arg=-Wl,-z,max-page-size=16384"
    output="lib$name.so"
    ;;
  linux-*)
    [[ "$(uname -s)" == Linux ]] || { echo 'Use tool/build_native_linux_docker.sh' >&2; exit 1; }
    native=no
    case "$(uname -m)/$target" in
      x86_64/linux-x64|aarch64/linux-arm64|riscv64/linux-riscv64) native=yes ;;
    esac
    if [[ "$native" == yes && -z "${SNE_SYSROOT:-}" ]]; then
      # The host compiler and pkg-config (Flatpak SDK, native CI runners).
      export "CARGO_TARGET_${key}_LINKER=${CC:-cc}"
    else
      export "CARGO_TARGET_${key}_LINKER=$cross-gcc"
      export "CC_${triple//-/_}=$cross-gcc"
      export PKG_CONFIG_ALLOW_CROSS=1
      export PKG_CONFIG_LIBDIR="${SNE_SYSROOT:-}/usr/lib/$cross/pkgconfig:${SNE_SYSROOT:-}/usr/share/pkgconfig"
      export PKG_CONFIG_SYSROOT_DIR="${SNE_SYSROOT:-/}"
    fi
    export "CARGO_TARGET_${key}_RUSTFLAGS=-C link-arg=-Wl,-soname,lib$name.so ${SNE_SYSROOT:+-C link-arg=--sysroot=$SNE_SYSROOT}"
    output="lib$name.so"
    ;;
  windows-*) output="$name.dll" ;;
esac
# Lock includes the mime_guess Git revision. Do not resolve new dependencies.
(cd "$root/rust" && "${cargo[@]}" build --manifest-path "$root/rust/Cargo.toml" --locked --release --target "$triple")
out="${SNE_OUTPUT:-$root/build/native/out/$target/$output}"
mkdir -p "$(dirname "$out")"
cat "$CARGO_TARGET_DIR/$triple/release/$output" > "$out"
chmod 755 "$out"
echo "Wrote $out"
