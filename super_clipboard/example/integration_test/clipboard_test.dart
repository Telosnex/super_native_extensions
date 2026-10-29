// Clipboard round trips through the system clipboard: each format is written
// with SystemClipboard, read back, and compared byte for byte.
//
// Desktop and mobile: flutter test integration_test/clipboard_test.dart -d <device>
// Web: flutter drive (see test_driver/integration_test.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:telosnex_web_test/telosnex_web_test.dart';

import 'clipboard_permission.dart';
import 'temp_file.dart';

// 2x2 images: red, blue / green, white.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACAgMAAAAP2OW3AAAADFBMVEX/AAAAAP8A/wD///9b'
    'HO1dAAAADElEQVQI12MQYNgAAADkAMH2i/cIAAAAAElFTkSuQmCC');
final _jpeg = base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoM'
    'DAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsN'
    'FBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAAR'
    'CAACAAIDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EAB4QAAEEAgMBAAAAAAAA'
    'AAAAAAECAwQGBQcACBEx/8QAFQEBAQAAAAAAAAAAAAAAAAAABAb/xAAeEQEAAgIDAAMAAAAA'
    'AAAAAAABAgMEBQAGERIhIv/aAAwDAQACEQMRAD8AddD63akyVHrsyZq2lypcjHRnXn369EW4'
    '4tTSSpSlFv0kkkkn77xfXu07+rTYddefcRKqwC2YARPAPl9HJ/S2Tz9Xi5mYtltlcJSlL9Sl'
    'KURlKUn1ZKqqqr68/9k=');
final _webp = base64Decode(
    'UklGRiwAAABXRUJQVlA4TB8AAAAvAUAAAB8gEEjeHzqN+RcQFPwf3fxHZA/gAg0R/Q8BAA==');
final _json = Uint8List.fromList(
    utf8.encode('{"name":"super_clipboard","items":[1,2,3],"text":"Grüße ✓"}'));

const _text = 'Hello, clipboard: Grüße, 世界, ✓ 😀\nSecond line\ttab';

final _uri = NamedUri(
  Uri.parse('https://example.com/path/a%20b?query=1&x=%C3%A9#fragment'),
  name: 'Example link',
);

// Chrome's async clipboard writes text/plain, text/html and image/png only.
const _webFileFormats =
    'the web clipboard writes text/plain, text/html and image/png only';
const _webFileUris = 'web has no file URIs';

/// Known bug: on Android a file URI goes into ClipData as file://, and
/// setPrimaryClip throws FileUriExposedException (targetSdk 24+), which
/// ends the app.
final _androidFileUriBug =
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? 'known bug: Android ends the app (FileUriExposedException)'
        : null;

/// Whether this platform can put a file URI on the clipboard.
final _fileUris = !kIsWeb && _androidFileUriBug == null;

/// Calls [IntegrationTestWidgetsFlutterBinding.ensureInitialized] and the web
/// test support. Call it once, first thing in main.
void setUpClipboardBinding() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  installWebTestSupport(binding);
}

void main() {
  setUpClipboardBinding();
  clipboardTests();
}

SystemClipboard get _clipboard {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) {
    throw StateError('SystemClipboard.instance is null on this platform');
  }
  return clipboard;
}

Future<void> _write(List<DataWriterItem> items) => _clipboard.write(items);

DataWriterItem _item(List<FutureOr<EncodedData>> data) {
  final item = DataWriterItem();
  for (final d in data) {
    item.add(d);
  }
  return item;
}

/// Reads the whole file of [format] from [reader], or null if it has none.
Future<Uint8List?> _readFile(DataReader reader, FileFormat format) {
  final completer = Completer<Uint8List?>();
  final progress = reader.getFile(
    format,
    (file) async {
      try {
        completer.complete(await file.readAll());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    },
    onError: (e) {
      if (!completer.isCompleted) completer.completeError(e);
    },
  );
  if (progress == null) return Future.value(null);
  return completer.future.timeout(const Duration(seconds: 20));
}

/// The RGBA pixels of an encoded image, to compare images that a platform
/// may re-encode (Chrome re-encodes PNG on write).
Future<List<int>> _pixels(Uint8List encoded) async {
  final codec = await ui.instantiateImageCodec(encoded);
  final frame = await codec.getNextFrame();
  final data =
      await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  final size = [frame.image.width, frame.image.height];
  frame.image.dispose();
  codec.dispose();
  return [...size, ...data!.buffer.asUint8List()];
}

Future<void> _expectFileRoundTrip(FileFormat format, Uint8List bytes) async {
  await _write([
    _item([format(bytes)])
  ]);
  final reader = await _clipboard.read();
  expect(reader.canProvide(format), isTrue,
      reason: 'formats on the clipboard: ${reader.platformFormats}');
  final read = await _readFile(reader, format);
  expect(read, isNotNull);
  expect(read, orderedEquals(bytes));
}

void clipboardTests() {
  group('SystemClipboard', () {
    setUpAll(waitForClipboardPermission);

    test('is available', () {
      expect(SystemClipboard.instance, isNotNull);
    });

    test('plainText round trip', () async {
      await _write([
        _item([Formats.plainText(_text)])
      ]);
      final reader = await _clipboard.read();
      expect(reader.canProvide(Formats.plainText), isTrue);
      expect(await reader.readValue(Formats.plainText), _text);
    });

    test('png round trip', () async {
      if (kIsWeb) {
        // Chrome decodes and re-encodes a PNG on write: compare the pixels.
        await _write([
          _item([Formats.png(_png)])
        ]);
        final reader = await _clipboard.read();
        final read = await _readFile(reader, Formats.png);
        expect(read, isNotNull);
        expect(await _pixels(read!), await _pixels(_png));
      } else {
        await _expectFileRoundTrip(Formats.png, _png);
      }
    });

    test('jpeg round trip', () async {
      await _expectFileRoundTrip(Formats.jpeg, _jpeg);
    }, skip: kIsWeb ? _webFileFormats : null);

    test('webp round trip', () async {
      await _expectFileRoundTrip(Formats.webp, _webp);
    }, skip: kIsWeb ? _webFileFormats : null);

    test('json round trip', () async {
      await _expectFileRoundTrip(Formats.json, _json);
    }, skip: kIsWeb ? _webFileFormats : null);

    test('uri round trip', () async {
      await _write([
        _item([Formats.uri(_uri)])
      ]);
      final reader = await _clipboard.read();
      expect(reader.canProvide(Formats.uri), isTrue);
      final read = await reader.readValue(Formats.uri);
      expect(read?.uri, _uri.uri);
    });

    test('fileUri round trip', () async {
      final file = await createTempFile('clip board ✓.txt', 'file contents');
      await _write([
        _item([Formats.fileUri(file)])
      ]);
      final reader = await _clipboard.read();
      expect(reader.canProvide(Formats.fileUri), isTrue,
          reason: 'formats on the clipboard: ${reader.platformFormats}');
      expect(await reader.readValue(Formats.fileUri), file);
    }, skip: kIsWeb ? _webFileUris : _androidFileUriBug);

    test('one item with every format', () async {
      final file = _fileUris
          ? await createTempFile('all formats.txt', 'all formats')
          : null;
      await _write([
        _item([
          Formats.plainText(_text),
          Formats.png(_png),
          Formats.jpeg(_jpeg),
          Formats.webp(_webp),
          Formats.json(_json),
          if (file != null) Formats.fileUri(file),
        ]),
      ]);
      final reader = await _clipboard.read();
      expect(await reader.readValue(Formats.plainText), _text);
      expect(await _readFile(reader, Formats.png), orderedEquals(_png));
      expect(await _readFile(reader, Formats.jpeg), orderedEquals(_jpeg));
      expect(await _readFile(reader, Formats.webp), orderedEquals(_webp));
      expect(await _readFile(reader, Formats.json), orderedEquals(_json));
      if (file != null) {
        expect(await reader.readValue(Formats.fileUri), file);
      }
    }, skip: kIsWeb ? _webFileFormats : null);

    // Copying several files.
    test('two items with a file URI each', () async {
      final a = await createTempFile('first file.txt', 'a');
      final b = await createTempFile('second file.txt', 'b');
      await _write([
        _item([Formats.fileUri(a)]),
        _item([Formats.fileUri(b)]),
      ]);
      final reader = await _clipboard.read();
      expect(reader.items, hasLength(2),
          reason: 'formats on the clipboard: ${reader.platformFormats}');
      expect(await reader.items[0].readValue(Formats.fileUri), a);
      expect(await reader.items[1].readValue(Formats.fileUri), b);
    }, skip: kIsWeb ? _webFileUris : _androidFileUriBug);

    // README: Windows and Linux keep only file URIs and URIs past the first
    // item.
    test('two items: text and image, then a file URI', () async {
      final file = await createTempFile('second item.txt', 'second');
      await _write([
        _item([Formats.plainText(_text), Formats.png(_png)]),
        _item([Formats.fileUri(file)]),
      ]);
      final reader = await _clipboard.read();
      expect(reader.items, hasLength(2),
          reason: 'formats on the clipboard: ${reader.platformFormats}');
      final first = reader.items[0];
      final second = reader.items[1];
      expect(await first.readValue(Formats.plainText), _text);
      expect(await _readFile(first, Formats.png), orderedEquals(_png));
      expect(await second.readValue(Formats.fileUri), file);
    },
        skip: kIsWeb
            ? 'the web clipboard writes one item only'
            : defaultTargetPlatform == TargetPlatform.linux ||
                    defaultTargetPlatform == TargetPlatform.windows
                ? "known bug: Linux and Windows list only the first item's "
                    'formats'
                : _androidFileUriBug);

    test('two items: text in each', () async {
      await _write([
        _item([Formats.plainText('first item')]),
        _item([Formats.plainText('second item')]),
      ]);
      final reader = await _clipboard.read();
      expect(reader.items, hasLength(2));
      expect(await reader.items[0].readValue(Formats.plainText), 'first item');
      expect(await reader.items[1].readValue(Formats.plainText), 'second item');
    },
        skip: kIsWeb
            ? 'the web clipboard writes one item only'
            : (defaultTargetPlatform == TargetPlatform.windows ||
                    defaultTargetPlatform == TargetPlatform.linux)
                ? 'only the first item can have text on Windows and Linux'
                : null);

    test('a new write replaces the old content', () async {
      await _write([
        _item([Formats.png(_png)])
      ]);
      await _write([
        _item([Formats.plainText('replacement')])
      ]);
      final reader = await _clipboard.read();
      expect(await reader.readValue(Formats.plainText), 'replacement');
      expect(reader.canProvide(Formats.png), isFalse,
          reason: 'formats on the clipboard: ${reader.platformFormats}');
    });

    test('empty write clears the clipboard', () async {
      await _write([
        _item([Formats.plainText('not cleared')])
      ]);
      await _write([]);
      final reader = await _clipboard.read();
      final text = await reader.readValue(Formats.plainText);
      expect(reader.canProvide(Formats.plainText), isFalse,
          reason: 'formats on the clipboard: ${reader.platformFormats}, '
              'text: $text');
      expect(text, isNull);
    },
        skip: kIsWeb
            ? "Chrome's clipboard.write([]) keeps the old content"
            : defaultTargetPlatform == TargetPlatform.android
                ? 'known bug: Android ends the app (setPrimaryClip(null))'
                : null);
  });
}
