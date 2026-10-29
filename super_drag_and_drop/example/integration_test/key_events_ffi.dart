// System key events: CGEventPost on macOS, SendInput on Windows. They go
// through the window server and the system's hot key matching, like a key
// press on a keyboard.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:super_hot_key/super_hot_key.dart';

/// Why system key events cannot be sent here, or null.
String? get keyEventsUnavailable {
  if (Platform.isWindows) return null;
  if (Platform.isMacOS) {
    if (!_axIsProcessTrusted()) {
      return 'CGEventPost needs the Accessibility permission, which this '
          'process does not have';
    }
    if (_macScreenLocked()) {
      return 'the screen is locked: macOS drops posted key events';
    }
    return null;
  }
  return 'no system key events on this platform';
}

/// Presses and releases the keys of [definition].
Future<void> pressKeys(HotKeyDefinition definition) async {
  if (Platform.isMacOS) return _pressMacOS(definition);
  if (Platform.isWindows) return _pressWindows(definition);
  throw UnsupportedError('no system key events on this platform');
}

// macOS

final _appServices = DynamicLibrary.open(
    '/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices');
final _axIsProcessTrusted = _appServices
    .lookupFunction<Bool Function(), bool Function()>('AXIsProcessTrusted');
final _cgEventCreateKeyboardEvent = _appServices.lookupFunction<
    Pointer<Void> Function(Pointer<Void>, Uint16, Bool),
    Pointer<Void> Function(
        Pointer<Void>, int, bool)>('CGEventCreateKeyboardEvent');
final _cgEventSetFlags = _appServices.lookupFunction<
    Void Function(Pointer<Void>, Uint64),
    void Function(Pointer<Void>, int)>('CGEventSetFlags');
final _cgEventPost = _appServices.lookupFunction<
    Void Function(Uint32, Pointer<Void>),
    void Function(int, Pointer<Void>)>('CGEventPost');
final _cfRelease = _appServices.lookupFunction<Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('CFRelease');
final _cgSessionCopyCurrentDictionary = _appServices.lookupFunction<
    Pointer<Void> Function(),
    Pointer<Void> Function()>('CGSessionCopyCurrentDictionary');
final _cfDictionaryGetValue = _appServices.lookupFunction<
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
    Pointer<Void> Function(
        Pointer<Void>, Pointer<Void>)>('CFDictionaryGetValue');
final _cfStringCreateWithCString = _appServices.lookupFunction<
    Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32),
    Pointer<Void> Function(
        Pointer<Void>, Pointer<Utf8>, int)>('CFStringCreateWithCString');
final _cfBooleanGetValue = _appServices.lookupFunction<
    Bool Function(Pointer<Void>),
    bool Function(Pointer<Void>)>('CFBooleanGetValue');

/// Whether the login session's screen is locked (CGSSessionScreenIsLocked).
bool _macScreenLocked() {
  final session = _cgSessionCopyCurrentDictionary();
  if (session == nullptr) return false;
  final key = using((arena) => _cfStringCreateWithCString(nullptr,
      'CGSSessionScreenIsLocked'.toNativeUtf8(allocator: arena), 0x08000100));
  try {
    final value = _cfDictionaryGetValue(session, key);
    return value != nullptr && _cfBooleanGetValue(value);
  } finally {
    _cfRelease(key);
    _cfRelease(session);
  }
}

// kVK_ codes (HIToolbox Events.h).
const _macKeyCodes = {
  0x00070042: 0x65, // F9
  0x0007000c: 0x22, // I
  0x00070008: 0x0e, // E
  0x0007000e: 0x28, // K
};

Future<void> _pressMacOS(HotKeyDefinition d) async {
  final code = _macKeyCodes[d.key.usbHidUsage]!;
  var flags = 0;
  if (d.shift) flags |= 1 << 17; // kCGEventFlagMaskShift
  if (d.control) flags |= 1 << 18; // kCGEventFlagMaskControl
  if (d.alt) flags |= 1 << 19; // kCGEventFlagMaskAlternate
  if (d.meta) flags |= 1 << 20; // kCGEventFlagMaskCommand
  for (final down in [true, false]) {
    final event = _cgEventCreateKeyboardEvent(nullptr, code, down);
    _cgEventSetFlags(event, flags);
    _cgEventPost(0, event); // kCGHIDEventTap
    _cfRelease(event);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

// Windows

final class _KeyboardInput extends Struct {
  @Uint32()
  external int type;
  @Uint32()
  external int padding;
  @Uint16()
  external int wVk;
  @Uint16()
  external int wScan;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @Uint32()
  external int padding2;
  @IntPtr()
  external int dwExtraInfo;
  // INPUT is as large as MOUSEINPUT (40 bytes on 64-bit Windows).
  @Uint64()
  external int padding3;
}

final _user32 = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
final _sendInput = _user32!.lookupFunction<
    Uint32 Function(Uint32, Pointer<_KeyboardInput>, Int32),
    int Function(int, Pointer<_KeyboardInput>, int)>('SendInput');

const _vkShift = 0x10, _vkControl = 0x11, _vkMenu = 0x12, _vkLWin = 0x5b;
const _windowsKeyCodes = {
  0x00070042: 0x78, // VK_F9
  0x0007000c: 0x49, // I
  0x00070008: 0x45, // E
  0x0007000e: 0x4b, // K
};

Future<void> _pressWindows(HotKeyDefinition d) async {
  final keys = [
    if (d.control) _vkControl,
    if (d.alt) _vkMenu,
    if (d.shift) _vkShift,
    if (d.meta) _vkLWin,
    _windowsKeyCodes[d.key.usbHidUsage]!,
  ];
  final events = [
    for (final k in keys) (k, false),
    for (final k in keys.reversed) (k, true),
  ];
  final inputs = calloc<_KeyboardInput>(events.length);
  try {
    for (var i = 0; i < events.length; i++) {
      inputs[i]
        ..type = 1 // INPUT_KEYBOARD
        ..wVk = events[i].$1
        ..dwFlags = events[i].$2 ? 2 : 0; // KEYEVENTF_KEYUP
    }
    // Key downs, then a pause so the release is seen apart, then key ups.
    final half = keys.length;
    final sent = _sendInput(half, inputs, sizeOf<_KeyboardInput>());
    if (sent != half) throw StateError('SendInput sent $sent of $half');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final sent2 = _sendInput(half, inputs + half, sizeOf<_KeyboardInput>());
    if (sent2 != half) throw StateError('SendInput sent $sent2 of $half');
  } finally {
    calloc.free(inputs);
  }
}
