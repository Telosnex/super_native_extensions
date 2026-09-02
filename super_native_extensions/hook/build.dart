import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // flutter-pi has no GTK plugin registrant or GDK display. Its application
    // gates all native SNE calls, so compiling the GTK backend would add an
    // unusable library and require an ARM GTK cross-sysroot for no benefit.
    if (Platform.environment['SUPER_NATIVE_EXTENSIONS_SKIP_NATIVE_BUILD'] ==
        'true') {
      return;
    }
    await const RustBuilder(
      assetName: 'super_native_extensions_native',
      cratePath: 'rust',
    ).run(input: input, output: output);
  });
}
