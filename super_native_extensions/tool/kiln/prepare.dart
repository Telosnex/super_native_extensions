/// Runs before each native build of the kiln release workflow
/// (.github/workflows/kiln_release.yml at the repository root), with
/// `dart tool/kiln/prepare.dart` in this package directory:
///
/// - macOS and iOS: selects Xcode 26.0.1.
/// - Linux: installs the toolchain of the pinned container with
///   tool/install_linux_build_toolchain.sh (GCC, GTK 3, rustup, QEMU) and
///   describes it in KILN_TOOLCHAIN.
///
/// Every target gets the Rust channel of rust/rust-toolchain.toml in
/// KILN_TOOLCHAIN_EXTRA.
library;

import 'dart:io';

const _xcode = '/Applications/Xcode_26.0.1.app/Contents/Developer';

Future<void> main() async {
  final env = Platform.environment;
  final target = env['TARGET']!;

  if (target.startsWith('macos-') || target.startsWith('ios-')) {
    await _run('sudo', ['xcode-select', '-s', _xcode]);
  }

  if (target.startsWith('linux-')) {
    await _run('git', [
      'config',
      '--global',
      '--add',
      'safe.directory',
      env['GITHUB_WORKSPACE']!,
    ]);
    await _run('bash', ['tool/install_linux_build_toolchain.sh', target]);
    _append(env['GITHUB_PATH']!, '${env['HOME']}/.cargo/bin');

    final compiler = target == 'linux-riscv64'
        ? 'riscv64-linux-gnu-gcc'
        : 'gcc';
    final os = RegExp(
      r'^PRETTY_NAME="(.*)"$',
      multiLine: true,
    ).firstMatch(File('/etc/os-release').readAsStringSync())![1]!;
    final version = await _run(compiler, ['--version'], quiet: true);
    final toolchain = '$os, ${version.split('\n').first.trim()}';
    stdout.writeln('KILN_TOOLCHAIN=$toolchain');
    _append(env['GITHUB_ENV']!, 'KILN_TOOLCHAIN=$toolchain');
  }

  final channel = RegExp(
    r'^channel = "(.*)"$',
    multiLine: true,
  ).firstMatch(File('rust/rust-toolchain.toml').readAsStringSync())![1]!;
  stdout.writeln('KILN_TOOLCHAIN_EXTRA=Rust $channel');
  _append(env['GITHUB_ENV']!, 'KILN_TOOLCHAIN_EXTRA=Rust $channel');
}

void _append(String file, String line) =>
    File(file).writeAsStringSync('$line\n', mode: FileMode.append);

Future<String> _run(
  String executable,
  List<String> args, {
  bool quiet = false,
}) async {
  if (!quiet) stdout.writeln('+ $executable ${args.join(' ')}');
  final result = await Process.run(executable, args);
  if (!quiet) {
    stdout.write(result.stdout);
    stderr.write(result.stderr);
  }
  if (result.exitCode != 0) {
    if (quiet) stderr.write(result.stderr);
    stderr.writeln('$executable: exit ${result.exitCode}');
    exit(result.exitCode);
  }
  return '${result.stdout}';
}
