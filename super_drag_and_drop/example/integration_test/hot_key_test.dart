// Global hot keys (super_hot_key): registration on macOS and Windows, a
// press from system key events, and null where they are unsupported.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_hot_key/super_hot_key.dart';

import 'binding.dart';
import 'key_events.dart';

final _supported = !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows);

const _unsupported = 'global hot keys exist on macOS and Windows only';

// The definitions of the app (Option+Shift+I and Option+Shift+E), and one
// for the press test that other apps are unlikely to use.
final _appDefinitions = [
  HotKeyDefinition(key: PhysicalKeyboardKey.keyI, alt: true, shift: true),
  HotKeyDefinition(key: PhysicalKeyboardKey.keyE, alt: true, shift: true),
];
final _pressDefinition = HotKeyDefinition(
    key: PhysicalKeyboardKey.keyK, alt: true, shift: true, control: true);

void main() {
  setUpBinding();
  hotKeyTests();
}

void hotKeyTests() {
  group('HotKey', () {
    test('create and dispose', () async {
      final hotKeys = <HotKey>[];
      for (final definition in _appDefinitions) {
        final hotKey = await HotKey.create(definition: definition);
        expect(hotKey, isNotNull);
        hotKeys.add(hotKey!);
      }
      for (final hotKey in hotKeys) {
        await hotKey.dispose();
      }
      // A disposed definition can be registered again.
      final again = await HotKey.create(definition: _appDefinitions.first);
      expect(again, isNotNull);
      await again!.dispose();
    }, skip: _supported ? null : _unsupported);

    test('create returns null where unsupported', () async {
      expect(await HotKey.create(definition: _appDefinitions.first), isNull);
    }, skip: _supported ? 'hot keys are supported here' : null);

    test('a key press calls onPressed and onReleased', () async {
      final pressed = Completer<void>();
      final released = Completer<void>();
      final hotKey = await HotKey.create(
        definition: _pressDefinition,
        onPressed: () => pressed.complete(),
        onReleased: () => released.complete(),
      );
      expect(hotKey, isNotNull);
      try {
        await pressKeys(_pressDefinition);
        await pressed.future.timeout(const Duration(seconds: 10));
        await released.future.timeout(const Duration(seconds: 10));
      } finally {
        await hotKey!.dispose();
      }
      // A disposed hot key no longer fires.
      var calls = 0;
      final other = await HotKey.create(
        definition: _pressDefinition,
        onPressed: () => calls++,
      );
      await other!.dispose();
      await pressKeys(_pressDefinition);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(calls, 0);
    }, skip: !_supported ? _unsupported : keyEventsUnavailable);

    // A definition that is taken must not give a HotKey that never fires.
    test('a taken definition is refused', () async {
      final first = await HotKey.create(definition: _pressDefinition);
      expect(first, isNotNull);
      try {
        HotKey? second;
        try {
          second = await HotKey.create(definition: _pressDefinition);
        } on PlatformException {
          second = null;
        }
        await second?.dispose();
        expect(second, isNull);
      } finally {
        await first!.dispose();
      }
    },
        skip: !_supported
            ? _unsupported
            : defaultTargetPlatform == TargetPlatform.macOS
                ? 'known bug: macOS ignores the status of RegisterEventHotKey'
                : null);
  });
}
