/// Runs after each native build of the kiln release workflow, with
/// `dart tool/kiln/test_build.dart`. On Linux it loads the library on its
/// target ABI (QEMU for riscv64) and checks the glibc baseline, with
/// tool/smoke_linux_library.sh.
library;

import 'dart:io';

Future<void> main() async {
  final env = Platform.environment;
  final target = env['TARGET']!;
  if (!target.startsWith('linux-')) return;

  final process = await Process.start(
    'bash',
    [
      'tool/smoke_linux_library.sh',
      target,
      '${env['OUT']}/out/$target/libsuper_native_extensions_native.so',
    ],
    mode: ProcessStartMode.inheritStdio,
  );
  exit(await process.exitCode);
}
