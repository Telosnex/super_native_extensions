# Native releases

Same flow as Telosnex's `zxing_dart`, `image_ffmpeg` and `fllama`
(package:kiln, ADR 001). `prebuilt.json` pins SHA-256-verified
libraries from an immutable GitHub release, keyed by the build inputs (the
source key: `rust/`, `hook/build.dart`, `pubspec.yaml`,
`tool/build_native_artifact.sh`; see `source_excludes.txt`). No binary is in
Git.

The hook downloads the library of the release when the sources match it.
Otherwise, or with user define `native_build: source`, it runs
`tool/build_native_artifact.sh` (Cargo). The release workflow runs the same
source build on every target: `dart run kiln:build`.

The asset ID remains
`package:super_native_extensions/super_native_extensions_native`.

## User defines

| Define | Effect |
|---|---|
| `native_build` | `auto` (default), `download`, or `source` (kiln) |
| `rust_toolchain: host` | Source build with the cargo on PATH, not rustup. For builds without network (Flatpak): `$HOME/.cargo/config.toml` must vendor the crates of `rust/Cargo.lock`. |
| `sysroot` | Target sysroot of a cross build (the linux-riscv64 release) |
| `skip_linux_arm64_native_build` | flutter-pi: with its compiler wrapper, no library for Linux ARM64 |

## Profile

- Rust 1.97.1 (`rust/rust-toolchain.toml`); `cargo build --locked --release`
  with the crate's LTO/size/panic-abort profile and symbol stripping. The
  lockfile pins the `mime_guess` Git dependency.
- Dynamic libraries only; strict static linking is unsupported.
- Apple: `@rpath` install names plus header padding for Flutter's rewriting.
- Android: API 24, NDK 28.2.13676358, 16KB LOAD alignment.
- Linux: canonical SONAME, no RPATH. GTK 3/GDK/GLib are system libraries,
  not bundled.

| Target keys | Release builder |
|---|---|
| `macos-arm64`, `macos-x64` | macos-15, Xcode 26.0.1, macOS 12 |
| `ios-arm64-iphoneos`, `ios-x64-iphonesimulator` | macos-15, Xcode 26.0.1, iOS 13 |
| `ios-arm64-iphonesimulator` | macos-15, Xcode 26.0.1, iOS 14 |
| `android-arm`, `android-arm64`, `android-x64` | NDK 28.2.13676358, API 24 |
| `linux-x64`, `linux-arm64` | native runners, Debian 11 container, glibc 2.31 |
| `linux-riscv64` | Ubuntu 22.04 container, cross GCC 11, glibc 2.35 |
| `windows-x64`, `windows-arm64` | windows-2022, MSVC |

## Release

```sh
git push -f origin HEAD:kiln-release-dry  # build every target, no upload
git push -f origin HEAD:kiln-release      # publish (owner only)
```

The release job pushes `kiln-manifest/<tag>` with `prebuilt.json`. Merge it.

## Local builds

Run from `super_native_extensions/`:

```sh
tool/build_native_artifact.sh macos-arm64      # -> build/native/out/<target>/
tool/build_native_linux_docker.sh linux-arm64  # release container + smoke test
```

`THIRD_PARTY_NOTICES.md`: `python3 tool/generate_native_notices.py`.
