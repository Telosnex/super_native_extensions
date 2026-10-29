import 'dart:io';

/// Creates [name] with [contents] in a new temporary directory and returns
/// its file URI.
Future<Uri> createTempFile(String name, String contents) async {
  final dir = await Directory.systemTemp.createTemp('super_clipboard_test');
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsString(contents);
  return file.absolute.uri;
}
