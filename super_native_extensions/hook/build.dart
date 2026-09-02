import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // flutter-pi has no GTK plugin registrant or GDK display. Its application
    // gates all native SNE calls, so compiling the GTK backend would add an
    // unusable library and require an ARM GTK cross-sysroot for no benefit.
    final compilerPath = input.config.code.cCompiler?.compiler.toFilePath();
    final skipLinuxArm64 =
        input.userDefines['skip_linux_arm64_native_build'] == true &&
        input.config.code.targetOS == OS.linux &&
        input.config.code.targetArchitecture == Architecture.arm64 &&
        compilerPath?.contains('/.native-assets-toolchain/') == true;
    if (skipLinuxArm64) {
      return;
    }
    await const RustBuilder(
      assetName: 'super_native_extensions_native',
      cratePath: 'rust',
    ).run(input: input, output: output);
  });
}
