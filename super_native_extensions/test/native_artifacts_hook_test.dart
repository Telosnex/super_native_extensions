import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../hook/build.dart';
import '../tool/verify_artifacts.dart' show expectedNativeTargets;

void main() {
  late Directory root;
  late BuildOutputBuilder output;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sne-artifact-test-');
    output = BuildOutputBuilder();
  });
  tearDown(() => root.delete(recursive: true));

  BuildInput input({
    String target = 'linux-arm64',
    bool web = false,
    bool skip = false,
    String? compiler,
    String linkMode = 'dynamic',
  }) {
    final parts = target.split('-');
    return BuildInput({
      'package_name': 'super_native_extensions',
      'package_root': '${root.path}/',
      'out_file': '${root.path}/out/output.json',
      'out_dir_shared': '${root.path}/shared/',
      'config': {
        'build_asset_types': [if (!web) 'code_assets/code'],
        'linking_enabled': false,
        if (!web)
          'extensions': {
            'code_assets': {
              'target_os': parts[0],
              'target_architecture': parts[1],
              'link_mode_preference': linkMode,
              if (parts[0] == 'ios')
                'ios': {
                  'target_sdk': parts[2],
                  'target_version': 13,
                },
              if (compiler != null)
                'c_compiler': {
                  'cc': compiler,
                  'ar': '/usr/bin/ar',
                  'ld': '/usr/bin/ld',
                },
            },
          },
      },
      'user_defines': {
        'workspace_pubspec': {
          'base_path': '${root.path}/pubspec.yaml',
          'defines': {'skip_linux_arm64_native_build': skip},
        },
      },
    });
  }

  Future<File> fixture(String target) async {
    final ext = target.startsWith('windows-')
        ? 'dll'
        : target.startsWith('ios-') || target.startsWith('macos-')
        ? 'dylib'
        : 'so';
    final relative = '$target/test.$ext';
    final source = File('${root.path}/native_artifacts/$relative');
    await source.parent.create(recursive: true);
    await source.writeAsBytes([1, 2, 3, 4]);
    await File('${root.path}/native_artifacts/manifest.json').writeAsString(
      jsonEncode({
        'schema': 1,
        'artifacts': {
          target: {
            'path': relative,
            'sha256': sha256.convert([1, 2, 3, 4]).toString(),
          },
        },
      }),
    );
    return source;
  }

  test('web needs neither code configuration nor manifest', () async {
    await buildArtifacts(input(web: true, skip: true), output);
    expect(output.build().assets.code, isEmpty);
  });
  test('flutter-pi skips before manifest access', () async {
    await buildArtifacts(
      input(
        skip: true,
        compiler: '/build/.native-assets-toolchain/aarch64-linux-gnu/clang',
      ),
      output,
    );
    expect(output.build().assets.code, isEmpty);
  });
  test('desktop ARM64 still gets the artifact with the app define', () async {
    await fixture('linux-arm64');
    await buildArtifacts(input(skip: true, compiler: '/usr/bin/clang'), output);
    expect(output.build().assets.code, hasLength(1));
  });
  test('flutter-pi compiler alone does not skip', () async {
    await fixture('linux-arm64');
    await buildArtifacts(
      input(
        compiler: '/build/.native-assets-toolchain/aarch64-linux-gnu/clang',
      ),
      output,
    );
    expect(output.build().assets.code, hasLength(1));
  });
  for (final target in expectedNativeTargets) {
    test(
      'publishes $target with original SNE asset ID and dependencies',
      () async {
        final source = await fixture(target);
        await buildArtifacts(input(target: target), output);
        final result = output.build();
        final asset = result.assets.code.single;
        expect(
          asset.id,
          'package:super_native_extensions/super_native_extensions_native',
        );
        expect(asset.linkMode, isA<DynamicLoadingBundled>());
        expect(await File.fromUri(asset.file!).readAsBytes(), [1, 2, 3, 4]);
        expect(result.dependencies, contains(source.uri));
        expect(
          result.dependencies,
          contains(root.uri.resolve('native_artifacts/manifest.json')),
        );
      },
    );
  }
  test('hash mismatch fails without emitting an asset', () async {
    await (await fixture('linux-arm64')).writeAsBytes([5]);
    await expectLater(buildArtifacts(input(), output), throwsStateError);
    expect(output.build().assets.code, isEmpty);
  });
  test('missing artifact fails', () async {
    await (await fixture('linux-arm64')).delete();
    await expectLater(buildArtifacts(input(), output), throwsStateError);
  });
  test('unsupported tuple fails without a source-build fallback', () async {
    await fixture('linux-arm64');
    await expectLater(
      buildArtifacts(input(target: 'linux-arm'), output),
      throwsUnsupportedError,
    );
  });
  test('strict static fails explicitly', () async {
    await expectLater(
      buildArtifacts(input(linkMode: 'static'), output),
      throwsUnsupportedError,
    );
  });
  test('soft static preference can use dynamic', () async {
    await fixture('linux-arm64');
    await buildArtifacts(input(linkMode: 'prefer_static'), output);
    expect(
      output.build().assets.code.single.linkMode,
      isA<DynamicLoadingBundled>(),
    );
  });
  test('unsupported manifest schema fails', () async {
    await fixture('linux-arm64');
    await File(
      '${root.path}/native_artifacts/manifest.json',
    ).writeAsString('{"schema": 2}');
    await expectLater(buildArtifacts(input(), output), throwsFormatException);
  });
  test(
    'publishes every checked-in artifact (not just test fixtures)',
    () async {
      final manifest =
          jsonDecode(
                await File('native_artifacts/manifest.json').readAsString(),
              )
              as Map<String, dynamic>;
      final artifacts = manifest['artifacts'] as Map<String, dynamic>;
      expect(artifacts.keys.toSet(), expectedNativeTargets);
      await Directory('${root.path}/native_artifacts').create();
      await File(
        'native_artifacts/manifest.json',
      ).copy('${root.path}/native_artifacts/manifest.json');
      for (final target in expectedNativeTargets) {
        final entry = artifacts[target] as Map<String, dynamic>;
        final relative = entry['path'] as String;
        final destination = File('${root.path}/native_artifacts/$relative');
        await destination.parent.create(recursive: true);
        await File('native_artifacts/$relative').copy(destination.path);
        final builder = BuildOutputBuilder();
        await buildArtifacts(input(target: target), builder);
        final published = File.fromUri(
          builder.build().assets.code.single.file!,
        );
        expect(
          (await sha256.bind(published.openRead()).first).toString(),
          entry['sha256'],
        );
      }
    },
  );
}
