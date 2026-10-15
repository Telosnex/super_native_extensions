/// Bundles the super_native_extensions Rust library as a Dart code asset.
///
/// With package:native_prebuilt (native_prebuilt ADR 001), the hook downloads
/// the library from the GitHub release in native_artifacts/prebuilt.json when
/// the package sources match it (user define `native_build`: auto, download or
/// source). Otherwise it runs tool/build_native_artifact.sh, which needs
/// rustup and the target's C toolchain (see that script). User defines:
/// `sysroot` for a cross build. `host_toolchain: true` (native_prebuilt's
/// standard define, also from its defaults.json) or `rust_toolchain: host`
/// builds with the cargo on PATH instead of rustup, for builds without
/// network (Flatpak). The crates of rust/Cargo.lock must then be vendored
/// in $HOME/.cargo; native_artifacts/sources.json lists the lock file for
/// packagers (`dart run native_prebuilt:flatpak`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_prebuilt/native_prebuilt.dart';

const _assetName = 'super_native_extensions_native';

const _targets = {
  'android-arm',
  'android-arm64',
  'android-x64',
  'ios-arm64-iphoneos',
  'ios-arm64-iphonesimulator',
  'ios-x64-iphonesimulator',
  'linux-arm64',
  'linux-riscv64',
  'linux-x64',
  'macos-arm64',
  'macos-x64',
  'windows-arm64',
  'windows-x64',
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    // flutter-pi has no GTK plugin registrant or GDK display. Its
    // capability-gated app does not need the library.
    final code = input.config.code;
    final skipLinuxArm64 =
        input.userDefines['skip_linux_arm64_native_build'] == true &&
        code.targetOS == OS.linux &&
        code.targetArchitecture == Architecture.arm64 &&
        code.cCompiler?.compiler.toFilePath().contains(
              '/.native-assets-toolchain/',
            ) ==
            true;
    if (skipLinuxArm64) return;

    // Production assets are dynamic libraries. A soft preference for static
    // can use dynamic; a strict request cannot.
    if (code.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError('SNE supports dynamic linking only.');
    }

    final stopwatch = Stopwatch()..start();
    final target = TargetName.of(code);
    if (!_targets.contains(target.name)) {
      throw UnsupportedError(
        'super_native_extensions has no native library for $target. '
        'Supported targets: ${_targets.join(', ')}.',
      );
    }
    await NativePrebuilt(
      input: input,
      output: output,
      log: _log,
    ).run((source) => _buildFromSource(input, output, target, source));
    _log('Hook completed in ${_formatDuration(stopwatch.elapsed)}');
  });
}

void _log(String message) =>
    stderr.writeln('[super_native_extensions] $message');

Future<void> _buildFromSource(
  BuildInput input,
  BuildOutputBuilder output,
  TargetName target,
  SourceBuild source,
) async {
  final shared = input.outputDirectoryShared;
  final hostToolchain =
      source.hostToolchain || input.userDefines['rust_toolchain'] == 'host';
  final library = File.fromUri(
    input.outputDirectory.resolve(
      target.os.dylibFileName('super_native_extensions_native'),
    ),
  );
  await Directory.fromUri(input.outputDirectory).create(recursive: true);

  // One Cargo target directory per target and toolchain mode. Cargo locks it
  // itself, but the lock keeps two app builds from racing on the output.
  final script = await File.fromUri(
    input.packageRoot.resolve('tool/build_native_artifact.sh'),
  ).readAsString();
  final environment = {
    'SNE_OUTPUT': library.path,
    if (hostToolchain) 'SNE_RUST_TOOLCHAIN': 'host',
    // A target sysroot for cross builds (linux-riscv64 in the release).
    if (input.userDefines['sysroot'] case final String sysroot)
      'SNE_SYSROOT': sysroot,
    if (target.os == OS.android) 'ANDROID_NDK_HOME': ?_androidNdk(),
  };
  final buildKey = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            target.name,
            hostToolchain,
            environment['SNE_SYSROOT'],
            script,
          ]),
        ),
      )
      .toString()
      .substring(0, 16);
  final targetDir = shared.resolve('cargo/${target.name}-$buildKey/');
  environment['SNE_CARGO_TARGET_DIR'] = targetDir.toFilePath();
  await _withLock(
    File.fromUri(shared.resolve('cargo/${target.name}-$buildKey.lock')),
    () => _run(
      'Building $target',
      input.packageRoot,
      ['tool/build_native_artifact.sh', target.name],
      environment,
    ),
  );

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _assetName,
      linkMode: DynamicLoadingBundled(),
      file: library.uri,
    ),
  );
}

/// The pinned NDK of the release builds, if it is installed.
String? _androidNdk() {
  final env = Platform.environment;
  final home = env['HOME'];
  for (final sdk in [
    ?env['ANDROID_HOME'],
    ?env['ANDROID_SDK_ROOT'],
    if (home != null) ...['$home/Library/Android/sdk', '$home/Android/Sdk'],
  ]) {
    final ndk = '$sdk/ndk/28.2.13676358';
    if (File('$ndk/source.properties').existsSync()) return ndk;
  }
  return env['ANDROID_NDK_HOME'];
}

Future<void> _run(
  String what,
  Uri packageRoot,
  List<String> bashArguments,
  Map<String, String> environment,
) async {
  _log(what);
  final stopwatch = Stopwatch()..start();
  // bash runs the script, so the file mode of a checkout does not matter.
  final process = await Process.start(
    bashExecutable(),
    bashArguments,
    workingDirectory: packageRoot.toFilePath(),
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw StateError(
      'super_native_extensions: ${bashArguments.join(' ')} failed with exit '
      'code $exitCode.',
    );
  }
  _log('$what took ${_formatDuration(stopwatch.elapsed)}');
}

Future<T> _withLock<T>(File lockFile, Future<T> Function() action) async {
  await lockFile.parent.create(recursive: true);
  final handle = await lockFile.open(mode: FileMode.append);
  try {
    await handle.lock(FileLock.blockingExclusive);
    return await action();
  } finally {
    await handle.close();
  }
}

String _formatDuration(Duration duration) {
  final millis = duration.inMilliseconds;
  if (millis < 1000) return '${millis}ms';
  final seconds = duration.inSeconds;
  if (seconds < 60) return '$seconds.${(millis % 1000) ~/ 100}s';
  return '${seconds ~/ 60}m ${seconds % 60}s';
}
