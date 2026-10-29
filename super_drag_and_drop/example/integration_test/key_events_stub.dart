import 'package:super_hot_key/super_hot_key.dart';

/// Why system key events cannot be sent here.
String? get keyEventsUnavailable => 'no system key events on the web';

Future<void> pressKeys(HotKeyDefinition definition) =>
    throw UnsupportedError('no system key events on the web');
