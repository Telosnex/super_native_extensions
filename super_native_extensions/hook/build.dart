import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

const _assetName = 'super_native_extensions_native';

final class _Artifact {
  const _Artifact({required this.path, required this.sha256});

  factory _Artifact.fromJson(Object? value, String key) {
    if (value case {'path': final String path, 'sha256': final String sha256}) {
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) &&
          path.split('/').length == 2 &&
          !path.contains('..') &&
          !path.contains('\\') &&
          path.startsWith('$key/')) {
        return _Artifact(path: path, sha256: sha256);
      }
    }
    throw FormatException('Invalid native artifact manifest entry for $key.');
  }

  final String path;
  final String sha256;
}

Future<void> main(List<String> args) => build(args, buildArtifacts);

Future<void> buildArtifacts(BuildInput input, BuildOutputBuilder output) async {
  if (!input.config.buildCodeAssets) return;

  // flutter-pi has no GTK plugin registrant or GDK display. Keep this before
  // manifest access: its capability-gated app does not need an SNE artifact.
  final skipLinuxArm64 =
      input.userDefines['skip_linux_arm64_native_build'] == true &&
      input.config.code.targetOS == OS.linux &&
      input.config.code.targetArchitecture == Architecture.arm64 &&
      input.config.code.cCompiler?.compiler.toFilePath().contains(
            '/.native-assets-toolchain/',
          ) ==
          true;
  if (skipLinuxArm64) return;

  // Like image_ffmpeg and zxing_dart, production assets are dynamic libraries.
  // A soft preference for static can use dynamic; a strict request cannot.
  if (input.config.code.linkModePreference == LinkModePreference.static) {
    throw UnsupportedError('SNE prebuilts support dynamic linking only.');
  }

  final manifestFile = File.fromUri(
    input.packageRoot.resolve('native_artifacts/manifest.json'),
  );
  final manifest = jsonDecode(await manifestFile.readAsString());
  if (manifest is! Map<String, Object?> || manifest['schema'] != 1) {
    throw const FormatException('Unsupported native artifact manifest.');
  }
  final encodedArtifacts = manifest['artifacts'];
  if (encodedArtifacts is! Map<String, Object?>) {
    throw const FormatException('Native artifact manifest has no artifacts.');
  }

  final os = input.config.code.targetOS;
  final architecture = input.config.code.targetArchitecture;
  final sdkSuffix = os == OS.iOS
      ? switch (input.config.code.iOS.targetSdk) {
          IOSSdk.iPhoneOS => '-iphoneos',
          IOSSdk.iPhoneSimulator => '-iphonesimulator',
          final sdk => throw UnsupportedError('Unsupported iOS SDK: $sdk.'),
        }
      : '';
  final key = '${os.name}-${architecture.name}$sdkSuffix';
  final encodedArtifact = encodedArtifacts[key];
  if (encodedArtifact == null) {
    throw UnsupportedError(
      'super_native_extensions has no pinned native artifact for $key. Supported targets: '
      '${encodedArtifacts.keys.join(', ')}.',
    );
  }
  final artifact = _Artifact.fromJson(encodedArtifact, key);

  final source = File.fromUri(
    input.packageRoot.resolve('native_artifacts/${artifact.path}'),
  );
  if (!await source.exists()) {
    throw StateError(
      'Pinned super_native_extensions artifact is missing: ${source.path}. Reinstall the '
      'package or rebuild it with the matching tool/build_* script.',
    );
  }
  final digest = (await sha256.bind(source.openRead()).first).toString();
  if (digest != artifact.sha256) {
    throw StateError(
      'SHA-256 mismatch for ${source.path}: expected ${artifact.sha256}, '
      'got $digest.',
    );
  }

  final outputDirectory = Directory.fromUri(input.outputDirectory);
  await outputDirectory.create(recursive: true);
  final outputName = os.dylibFileName('super_native_extensions_native');
  final published = File.fromUri(input.outputDirectory.resolve(outputName));
  await source.copy(published.path);

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _assetName,
      linkMode: DynamicLoadingBundled(),
      file: published.uri,
    ),
  );
  output.dependencies.addAll([
    input.packageRoot.resolve('hook/build.dart'),
    manifestFile.uri,
    source.uri,
  ]);
}
