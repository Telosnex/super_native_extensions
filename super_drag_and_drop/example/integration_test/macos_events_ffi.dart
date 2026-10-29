// Mouse events for the app's own window on macOS, through AppKit
// ([NSWindow sendEvent:]). They go through the same path as the events of a
// real mouse: AppKit, the FlutterView (where super_native_extensions keeps
// the mouse-down event that a drag session needs), and the engine. No
// Accessibility permission is needed: nothing is posted to the system.
import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';

final _objc = DynamicLibrary.process();

final _getClass = _objc.lookupFunction<Pointer<Void> Function(Pointer<Utf8>),
    Pointer<Void> Function(Pointer<Utf8>)>('objc_getClass');
final _registerName = _objc.lookupFunction<
    Pointer<Void> Function(Pointer<Utf8>),
    Pointer<Void> Function(Pointer<Utf8>)>('sel_registerName');
final _msgSendPtr = _objc.lookup<Void>('objc_msgSend');

final _sendId = _msgSendPtr
    .cast<
        NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>>()
    .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>();
final _sendIdId = _msgSendPtr
    .cast<
        NativeFunction<
            Pointer<Void> Function(
                Pointer<Void>, Pointer<Void>, Pointer<Void>)>>()
    .asFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>();
final _sendIdLong = _msgSendPtr
    .cast<
        NativeFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Int64)>>()
    .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int)>();
final _sendLong = _msgSendPtr
    .cast<NativeFunction<Int64 Function(Pointer<Void>, Pointer<Void>)>>()
    .asFunction<int Function(Pointer<Void>, Pointer<Void>)>();
final _sendDouble = _msgSendPtr
    .cast<NativeFunction<Double Function(Pointer<Void>, Pointer<Void>)>>()
    .asFunction<double Function(Pointer<Void>, Pointer<Void>)>();
final _sendBool = _msgSendPtr
    .cast<NativeFunction<Bool Function(Pointer<Void>, Pointer<Void>)>>()
    .asFunction<bool Function(Pointer<Void>, Pointer<Void>)>();

final _postEvent = _msgSendPtr
    .cast<
        NativeFunction<
            Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Bool)>>()
    .asFunction<
        void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, bool)>();

final class _NSPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

final _mouseEvent = _msgSendPtr
    .cast<
        NativeFunction<
            Pointer<Void> Function(
                Pointer<Void>,
                Pointer<Void>,
                Uint64,
                _NSPoint,
                Uint64,
                Double,
                Int64,
                Pointer<Void>,
                Int64,
                Int64,
                Float)>>()
    .asFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int, _NSPoint, int,
            double, int, Pointer<Void>, int, int, double)>();

Pointer<Void> _cls(String name) =>
    using((a) => _getClass(name.toNativeUtf8(allocator: a)));
Pointer<Void> _sel(String name) =>
    using((a) => _registerName(name.toNativeUtf8(allocator: a)));

/// Whether this process can send AppKit events from Dart: macOS on ARM64
/// (objc_msgSend returns structs in registers), on the main thread.
bool get canSendMacOSEvents {
  if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) return false;
  return _sendBool(_cls('NSThread'), _sel('isMainThread'));
}

Pointer<Void> _window() {
  final app = _sendId(_cls('NSApplication'), _sel('sharedApplication'));
  for (final name in ['keyWindow', 'mainWindow']) {
    final w = _sendId(app, _sel(name));
    if (w != nullptr) return w;
  }
  final windows = _sendId(app, _sel('windows'));
  if (_sendLong(windows, _sel('count')) == 0) {
    throw StateError('the app has no window');
  }
  return _sendIdLong(windows, _sel('objectAtIndex:'), 0);
}

const leftMouseDown = 1;
const leftMouseUp = 2;
const leftMouseDragged = 6;

/// Sends a mouse event of [type] at [position] (logical pixels from the top
/// left of [view]) to the app's window. With [post], the event goes to the
/// end of the app's event queue ([NSApplication postEvent:atStart:]) and
/// this returns at once.
void sendMacOSMouseEvent(FlutterView view, int type, Offset position,
    {bool post = false}) {
  final window = _window();
  final height = view.physicalSize.height / view.devicePixelRatio;
  final timestamp = _sendDouble(
      _sendId(_cls('NSProcessInfo'), _sel('processInfo')),
      _sel('systemUptime'));
  final point = calloc<_NSPoint>();
  try {
    // Window coordinates start at the bottom left.
    point.ref
      ..x = position.dx
      ..y = height - position.dy;
    final event = _mouseEvent(
      _cls('NSEvent'),
      _sel('mouseEventWithType:location:modifierFlags:timestamp:'
          'windowNumber:context:eventNumber:clickCount:pressure:'),
      type,
      point.ref,
      0,
      timestamp,
      _sendLong(window, _sel('windowNumber')),
      nullptr,
      0,
      1,
      type == leftMouseUp ? 0.0 : 1.0,
    );
    if (post) {
      final app = _sendId(_cls('NSApplication'), _sel('sharedApplication'));
      _postEvent(app, _sel('postEvent:atStart:'), event, false);
    } else {
      _sendIdId(window, _sel('sendEvent:'), event);
    }
  } finally {
    calloc.free(point);
  }
}
