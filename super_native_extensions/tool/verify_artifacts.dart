import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const expectedNativeTargets = {
  'macos-arm64',
  'macos-x64',
  'ios-arm64-iphoneos',
  'ios-arm64-iphonesimulator',
  'ios-x64-iphonesimulator',
  'android-arm',
  'android-arm64',
  'android-x64',
  'linux-arm64',
  'linux-x64',
  'linux-riscv64',
  'windows-x64',
  'windows-arm64',
};

Future<void> main() async {
  final root = Directory.current;
  final manifest = jsonDecode(
    await File('${root.path}/native_artifacts/manifest.json').readAsString(),
  );
  if (manifest is! Map<String, Object?> ||
      manifest['schema'] != 1 ||
      manifest['profile'] != 1) {
    throw const FormatException('Unsupported artifact manifest/profile');
  }
  final native = manifest['artifacts'];
  if (native is! Map<String, Object?> ||
      native.keys.toSet().difference(expectedNativeTargets).isNotEmpty ||
      expectedNativeTargets.difference(native.keys.toSet()).isNotEmpty) {
    throw const FormatException('Native artifact matrix mismatch');
  }
  final sources = manifest['sources'] as Map<String, Object?>;
  final lock = File('${root.path}/rust/Cargo.lock');
  if (sha256.convert(await lock.readAsBytes()).toString() !=
      sources['cargo_lock_sha256']) {
    throw StateError('Cargo.lock changed: rebuild the native artifacts.');
  }
  var failed = false;
  for (final MapEntry(key: target, value: encoded) in native.entries) {
    if (encoded case {'path': final String path, 'sha256': final String hash}) {
      final file = File('${root.path}/native_artifacts/$path');
      if (!await file.exists()) {
        stderr.writeln('MISSING $target: ${file.path}');
        failed = true;
        continue;
      }
      final actual = (await sha256.bind(file.openRead()).first).toString();
      if (actual != hash) {
        stderr.writeln('MISMATCH $target: expected $hash, got $actual');
        failed = true;
      } else {
        stdout.writeln('OK $target $actual');
      }
    } else {
      throw FormatException('Malformed native artifact: $target');
    }
  }
  if (failed) exitCode = 1;
}
