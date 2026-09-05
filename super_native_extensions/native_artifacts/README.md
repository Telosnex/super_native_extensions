# Pinned production artifacts

Same consumer flow as Telosnex's `zxing_dart` and `image_ffmpeg`: committed
libraries plus a schema-1 SHA-256 manifest. The build hook verifies and copies
one library into a bundled `CodeAsset`; it never downloads binaries, runs Cargo,
or falls back to a local source build. No Git LFS is required.

The original asset ID remains
`package:super_native_extensions/super_native_extensions_native`.
The Dart API and platform plugin registrants are unchanged.

## Profile 1

- Rust 1.97.1; `cargo build --locked --release`, with the crate's existing
  LTO/size optimization/panic-abort profile and symbol stripping.
- All tracked Rust input bytes and Cargo.lock are fingerprinted. The lockfile
  pins the `mime_guess` Git dependency too; no dependency resolution on release.
- Dynamic libraries on every platform, as in the two precedent packages.
  Strict static linking is explicitly unsupported (no silent link-mode change).
- Apple: `@rpath` install names plus header padding for Flutter's rewriting.
- Android: API 24, NDK 28.2.13676358, 16KB LOAD alignment (including ARMv7).
- Linux: canonical SONAME, no embedded RPATH/RUNPATH.
- Each target's `build.json` records source/lock fingerprints, compiler/host,
  binary hash, original CI run and build revision, and native load-smoke status.
  CI runner labels and Ubuntu package mirrors are not immutable compiler
  snapshots: the committed binaries/hashes, not bit-identical future builds,
  are the consumer reproducibility guarantee.

## Matrix

| Target keys | Build baseline |
|---|---|
| `macos-arm64`, `macos-x64` | Xcode 26.0.1, macOS 12 |
| `ios-arm64-iphoneos`, `ios-x64-iphonesimulator` | Xcode 26.0.1, iOS 13 |
| `ios-arm64-iphonesimulator` | Xcode 26.0.1, iOS 14 |
| `android-arm`, `android-arm64`, `android-x64` | NDK 28.2.13676358, API 24 |
| `linux-x64`, `linux-arm64` | Debian 11, glibc 2.31, GCC 10 |
| `linux-riscv64` | Ubuntu 22.04, glibc 2.35, GCC 11; `riscv64gc-unknown-linux-gnu` |
| `windows-x64`, `windows-arm64` | Windows Server 2022 runner, MSVC |

Linux artifacts dynamically depend on GTK 3/GDK/GLib and related system
libraries. Those are **not bundled**, and these binaries still require normal
Flutter GTK plugin registration. RISC-V artifact availability does not imply
that stock Flutter supports deploying to a RISC-V desktop.

Web emits no native asset and does not read code-assets configuration.
The explicit flutter-pi define **and** its distinctive compiler wrapper still
omit the Linux ARM64 artifact before manifest access. Ordinary ARM64 GTK
Flutter builds get the prebuilt, even if the app's Pi define is present.

## Rebuild and import

Run from `super_native_extensions/` (the package, not the monorepo root):

```sh
# Local Apple/Android production builds:
tool/build_native_artifact.sh macos-arm64
tool/build_native_artifact.sh ios-arm64-iphoneos
tool/build_native_artifact.sh android-arm64

# Linux cross builds in digest-pinned containers with target GTK sysroots:
tool/build_native_linux_docker.sh linux-x64
tool/build_native_linux_docker.sh linux-arm64
tool/build_native_linux_docker.sh linux-riscv64

# Windows: run under Git Bash on a VS 2022 host with x64/ARM64 C++ tools:
tool/build_native_artifact.sh windows-arm64

# Or build the whole matrix on GitHub Actions (build-only, no automatic commit):
gh workflow run native_artifacts.yml --repo Telosnex/super_native_extensions --ref main
# Optional subset:
gh workflow run native_artifacts.yml --repo Telosnex/super_native_extensions \
  --ref main -f 'targets=["linux-riscv64"]'

# Import only successful uploaded job outputs, verifying their hashes:
tool/import_ci_artifacts.sh RUN_ID
python3 tool/native_artifacts.py assemble
python3 tool/generate_native_notices.py

# Check source freshness, complete matrix, provenance, and every binary hash:
python3 tool/native_artifacts.py verify
dart run tool/verify_artifacts.dart
flutter test test/native_artifacts_hook_test.dart

# Load/lookup existing Linux artifacts natively or under QEMU, without Cargo:
tool/build_native_linux_docker.sh linux-riscv64 verify
```

The assembler rejects missing targets, stale Rust sources, changed Cargo.lock,
and binaries that no longer match their build provenance. Review and commit
libraries, build.json files, manifest, and notices together. Never reuse the
old Cargokit 0.9 prebuilts for these 0.10 sources.

Build-time validation checks architecture and entrypoint exports, ELF
SONAME/RPATH and Android page alignment, Apple SDK/install-name rewriting,
and host-native library loading. Linux production builds additionally perform
an actual load/lookup under native execution or QEMU. This is not a clipboard,
drag/drop, or engine-registration integration test; those require a Flutter
application on each platform. Windows ARM64 and Apple mobile artifacts are
cross-built/structurally checked, not device-runtime tested by this workflow.

SNE's license is in `../LICENSE`; locked crate licenses/notices are collected
in `THIRD_PARTY_NOTICES.md`. Retain those when redistributing the binaries.

## Initial acceptance

All 13 artifacts were built and verified. The committed Linux x64, ARM64, and
RISC-V libraries passed actual load/entrypoint lookup (native/QEMU) in
[run 33986133800](https://github.com/Telosnex/super_native_extensions/actions/runs/33986133800).
The package analyzer and 25 tests passed, including hook selection against every
real committed artifact. Telosnex built successfully for web, macOS release,
iOS release without codesigning, and flutter-pi (with SNE correctly omitted).
