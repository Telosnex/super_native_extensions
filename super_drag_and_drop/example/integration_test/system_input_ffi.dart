// System mouse input that the platform's drag session follows: SendInput
// on Windows, xdotool on Linux (X11). Like a mouse, they move the cursor of
// the whole session: run them on a desktop that no one uses.
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:ffi/ffi.dart';

/// Why system mouse input cannot be sent here, or null.
String? get systemMouseUnavailable {
  if (Platform.isWindows) return null;
  if (Platform.isLinux) {
    if ((Platform.environment['DISPLAY'] ?? '').isEmpty) {
      return 'xdotool needs an X11 display (DISPLAY is not set)';
    }
    if (Process.runSync('which', ['xdotool']).exitCode != 0) {
      return 'xdotool is not installed';
    }
    return null;
  }
  return 'no system mouse input on this platform';
}

/// Drags with the system mouse from [from] to [to] (logical pixels in
/// [view]): press, move in steps, release.
Future<void> systemMouseDrag(FlutterView view, Offset from, Offset to) async {
  if (Platform.isWindows) {
    // DoDragDrop runs a modal loop on the platform thread, which also runs
    // this isolate: another isolate (thread) moves the mouse meanwhile.
    final ratio = view.devicePixelRatio;
    final (x, y) = _WindowsMouse.viewOrigin();
    final (fx, fy, tx, ty) = (from.dx, from.dy, to.dx, to.dy);
    await Isolate.run(() => _drag(
          _WindowsMouse(x, y, ratio),
          Offset(fx, fy),
          Offset(tx, ty),
          (ms) async => sleep(Duration(milliseconds: ms)),
        ));
    return;
  }
  await _drag(await _X11Mouse.of(view), from, to,
      (ms) => Future<void>.delayed(Duration(milliseconds: ms)));
}

Future<void> _drag(_Mouse mouse, Offset from, Offset to,
    Future<void> Function(int ms) pause) async {
  await mouse.move(from);
  await pause(50);
  await mouse.button(down: true);
  await pause(50);
  const steps = 15;
  for (var i = 1; i <= steps; i++) {
    await mouse.move(Offset.lerp(from, to, i / steps)!);
    await pause(50);
  }
  // Drop targets see the last position before the release.
  await pause(500);
  await mouse.move(to + const Offset(1, 1));
  await pause(50);
  await mouse.move(to);
  await pause(300);
  await mouse.button(down: false);
}

abstract class _Mouse {
  Future<void> move(Offset logical);
  Future<void> button({required bool down});
}

// Windows

final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class _MouseInput extends Struct {
  @Uint32()
  external int type;
  @Uint32()
  external int padding;
  @Int32()
  external int dx;
  @Int32()
  external int dy;
  @Uint32()
  external int mouseData;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @Uint32()
  external int padding2;
  @IntPtr()
  external int dwExtraInfo;
}

final _user32 = DynamicLibrary.open('user32.dll');
final _findWindow = _user32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
    int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
final _findWindowEx = _user32.lookupFunction<
    IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
    int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
final _clientToScreen = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<_Point>),
    int Function(int, Pointer<_Point>)>('ClientToScreen');
final _setCursorPos = _user32.lookupFunction<Int32 Function(Int32, Int32),
    int Function(int, int)>('SetCursorPos');
final _setForegroundWindow =
    _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetForegroundWindow');
final _sendInput = _user32.lookupFunction<
    Uint32 Function(Uint32, Pointer<_MouseInput>, Int32),
    int Function(int, Pointer<_MouseInput>, int)>('SendInput');

/// Plain values only: it is built in the isolate that moves the mouse.
class _WindowsMouse implements _Mouse {
  _WindowsMouse(this._x, this._y, this._ratio);

  final int _x;
  final int _y;
  final double _ratio;

  /// The screen position of the Flutter view's client area. Brings the
  /// window to the front.
  static (int, int) viewOrigin() => using((arena) {
        final window = _findWindow(
            'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: arena),
            nullptr);
        if (window == 0) throw StateError('no Flutter window');
        _setForegroundWindow(window);
        final child = _findWindowEx(
            window, 0, 'FLUTTERVIEW'.toNativeUtf16(allocator: arena), nullptr);
        final point = arena<_Point>();
        _clientToScreen(child != 0 ? child : window, point);
        return (point.ref.x, point.ref.y);
      });

  @override
  Future<void> move(Offset logical) async {
    _setCursorPos(
        _x + (logical.dx * _ratio).round(), _y + (logical.dy * _ratio).round());
    _send(0x0001); // MOUSEEVENTF_MOVE by 0: a move message.
  }

  @override
  Future<void> button({required bool down}) async {
    _send(down ? 0x0002 : 0x0004); // MOUSEEVENTF_LEFTDOWN / LEFTUP
  }

  void _send(int flags) {
    final input = calloc<_MouseInput>();
    try {
      input.ref
        ..type = 0 // INPUT_MOUSE
        ..dwFlags = flags;
      final sent = _sendInput(1, input, sizeOf<_MouseInput>());
      if (sent != 1) throw StateError('SendInput sent no input');
    } finally {
      calloc.free(input);
    }
  }
}

// Linux (X11)

class _X11Mouse implements _Mouse {
  _X11Mouse(this.view, this._x, this._y);

  final FlutterView view;
  final int _x;
  final int _y;

  /// Finds the screen position of this app's view: the window of this
  /// process with the view's size.
  static Future<_X11Mouse> of(FlutterView view) async {
    final width = view.physicalSize.width.round();
    final height = view.physicalSize.height.round();
    final ids = (await _xdotool(['search', '--onlyvisible', '--pid', '$pid']))
        .split('\n')
        .where((l) => l.trim().isNotEmpty);
    final found = <String>[];
    for (final id in ids) {
      final geometry = await _xdotool(['getwindowgeometry', '--shell', id]);
      final values = {
        for (final line in geometry.split('\n'))
          if (line.contains('='))
            line.split('=')[0]: int.parse(line.split('=')[1]),
      };
      found.add('$id $values');
      final w = values['WIDTH']!, h = values['HEIGHT']!;
      if ((w - width).abs() <= 2 && h >= height && h - height < 100) {
        // A header bar above the view, if any.
        return _X11Mouse(view, values['X']!, values['Y']! + h - height);
      }
    }
    throw StateError('no window of ${width}x$height for pid $pid: $found');
  }

  @override
  Future<void> move(Offset logical) async {
    final ratio = view.devicePixelRatio;
    await _xdotool([
      'mousemove',
      '${_x + (logical.dx * ratio).round()}',
      '${_y + (logical.dy * ratio).round()}',
    ]);
  }

  @override
  Future<void> button({required bool down}) async {
    await _xdotool([down ? 'mousedown' : 'mouseup', '1']);
  }

  static Future<String> _xdotool(List<String> args) async {
    final result = await Process.run('xdotool', args);
    if (result.exitCode != 0 && args.first != 'search') {
      throw StateError('xdotool ${args.join(' ')}: ${result.stderr}');
    }
    return result.stdout as String;
  }
}
