import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Waits until the page may read and write the clipboard. The driver
/// (test_driver/integration_test.dart) grants it after the page loads, and
/// the tests start at load.
Future<void> waitForClipboardPermission() async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  for (final name in ['clipboard-read', 'clipboard-write']) {
    while (true) {
      final status = await web.window.navigator.permissions
          .query({'name': name}.jsify()! as JSObject)
          .toDart;
      if (status.state == 'granted') break;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('$name is ${status.state}, not granted');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
