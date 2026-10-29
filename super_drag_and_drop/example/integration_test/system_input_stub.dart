import 'dart:ui';

/// Why system mouse input cannot be sent here, or null.
String? get systemMouseUnavailable => 'no system mouse input on the web';

/// Drags with the system mouse from [from] to [to] (logical pixels in
/// [view]).
Future<void> systemMouseDrag(FlutterView view, Offset from, Offset to) =>
    throw UnsupportedError('no system mouse input on the web');
