// Drag and drop without a human: a DragItemWidget and a DropRegion in one
// app, and a drag between them from synthesized pointer input.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import 'binding.dart';
import 'macos_events.dart';
import 'system_input.dart';

final _dragKey = GlobalKey();
final _dropKey = GlobalKey();

const _dragText = 'dragged text ✓';
const _localData = {'source': 'drag_and_drop_test', 'n': 1};

/// What the DropRegion and the drag session saw.
class _Events {
  final over = <DropOverEvent>[];
  int enter = 0;
  int leave = 0;
  int ended = 0;
  final performed = Completer<PerformDropEvent>();
  String? droppedText;
  Object? droppedLocalData;
  DragSession? session;
  final started = Completer<void>();
  final completed = Completer<DropOperation>();
  void Function()? onDragRequested;
}

Widget _app(_Events events) {
  return MaterialApp(
    home: Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: DragItemWidget(
              key: _dragKey,
              allowedOperations: () => [DropOperation.copy],
              dragItemProvider: (request) {
                events.onDragRequested?.call();
                final session = request.session;
                events.session = session;
                void onDragging() {
                  if (session.dragging.value && !events.started.isCompleted) {
                    events.started.complete();
                  }
                }

                void onCompleted() {
                  final operation = session.dragCompleted.value;
                  if (operation != null && !events.completed.isCompleted) {
                    events.completed.complete(operation);
                  }
                }

                session.dragging.addListener(onDragging);
                session.dragCompleted.addListener(onCompleted);
                final item = DragItem(localData: _localData);
                item.add(Formats.plainText(_dragText));
                return item;
              },
              child: DraggableWidget(
                child: Container(
                  width: 160,
                  height: 60,
                  color: Colors.blue,
                  alignment: Alignment.center,
                  child: const Text('Drag me'),
                ),
              ),
            ),
          ),
          const SizedBox(height: 60),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: DropRegion(
              key: _dropKey,
              formats: const [Formats.plainText, Formats.png, Formats.fileUri],
              hitTestBehavior: HitTestBehavior.opaque,
              onDropEnter: (_) => events.enter++,
              onDropLeave: (_) => events.leave++,
              onDropEnded: (_) => events.ended++,
              onDropOver: (event) {
                events.over.add(event);
                return event.session.allowedOperations
                        .contains(DropOperation.copy)
                    ? DropOperation.copy
                    : DropOperation.none;
              },
              onPerformDrop: (event) async {
                final item = event.session.items.first;
                events.droppedLocalData = item.localData;
                final reader = item.dataReader;
                if (reader != null && reader.canProvide(Formats.plainText)) {
                  final text = Completer<String?>();
                  reader.getValue<String>(Formats.plainText, text.complete,
                      onError: text.completeError);
                  events.droppedText = await text.future;
                }
                events.performed.complete(event);
              },
              child: Container(
                width: 240,
                height: 160,
                color: Colors.green,
                alignment: Alignment.center,
                child: const Text('Drop here'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Sends pointer data to the engine's entry point, as the platform does.
/// The drag driver of the web replaces that callback during a drag, so it
/// is read on each call.
class _PointerInjector {
  _PointerInjector(this.view);

  final ui.FlutterView view;
  static const _device = 7;
  static const _pointer = 7;
  final _start = DateTime.now();

  Offset? _last;

  void _send(ui.PointerChange change, Offset position, int buttons) {
    final ratio = view.devicePixelRatio;
    // The engine sends the delta of each move; gesture slop uses it.
    final delta = position - (_last ?? position);
    _last = position;
    final data = ui.PointerData(
      viewId: view.viewId,
      timeStamp: DateTime.now().difference(_start),
      change: change,
      kind: ui.PointerDeviceKind.mouse,
      device: _device,
      pointerIdentifier: _pointer,
      physicalX: position.dx * ratio,
      physicalY: position.dy * ratio,
      physicalDeltaX: delta.dx * ratio,
      physicalDeltaY: delta.dy * ratio,
      buttons: buttons,
    );
    ui.PlatformDispatcher.instance
        .onPointerDataPacket!(ui.PointerDataPacket(data: [data]));
  }

  Future<void> drag(Offset from, Offset to, {int steps = 12}) async {
    if (canSendMacOSEvents) return _dragMacOS(from, to, steps);
    _send(ui.PointerChange.add, from, 0);
    _send(ui.PointerChange.hover, from, 0);
    await _frame();
    _send(ui.PointerChange.down, from, kPrimaryButton);
    await _frame();
    for (var i = 1; i <= steps; i++) {
      final p = Offset.lerp(from, to, i / steps)!;
      _send(ui.PointerChange.move, p, kPrimaryButton);
      await _frame();
    }
    // Let the drop region see the last position before the release.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _send(ui.PointerChange.move, to, kPrimaryButton);
    await _frame();
    _send(ui.PointerChange.up, to, 0);
    await _frame();
  }

  Future<void> _dragMacOS(Offset from, Offset to, int steps) async {
    sendMacOSMouseEvent(view, leftMouseDown, from, post: true);
    await _frame();
    for (var i = 1; i <= steps; i++) {
      sendMacOSMouseEvent(
          view, leftMouseDragged, Offset.lerp(from, to, i / steps)!,
          post: true);
      await _frame();
    }
  }

  static Future<void> _frame() =>
      Future<void>.delayed(const Duration(milliseconds: 32));
}

/// Mobile drags start from system touches, which an app cannot synthesize.
final String? _mobile = kIsWeb
    ? null
    : defaultTargetPlatform == TargetPlatform.iOS
        ? 'UIDragInteraction starts a drag from system touches only'
        : defaultTargetPlatform == TargetPlatform.android
            ? 'View.startDragAndDrop starts no drag without a real touch'
            : null;

/// Windows and Linux: the drag session follows the system mouse.
final _useSystemMouse = !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

/// Why a drag session cannot start here without a human, or null.
final String? _noDrag =
    _mobile ?? (_useSystemMouse ? systemMouseUnavailable : null);

/// Why a drag cannot be carried to a drop here without a human, or null.
final String? _noFullDrop = _noDrag ??
    (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
        ? 'AppKit tracks the system mouse in a drag session; moving it '
            'needs the Accessibility permission (CGEventPost)'
        : null);

/// Drags from the DragItemWidget to the DropRegion with input that the
/// platform's drag session follows: engine pointer data on the web (the
/// drag runs in Flutter), AppKit mouse events on macOS (the session starts
/// and ends at once: AppKit then tracks the real mouse, whose button is
/// up), and the system mouse on Windows and Linux.
Future<void> _drag(WidgetTester tester, _Events events) async {
  final from = _center(_dragKey);
  final to = _center(_dropKey);
  if (_useSystemMouse) {
    await systemMouseDrag(tester.view, from, to);
  } else if (canSendMacOSEvents) {
    // The AppKit drag session runs on the main thread, which runs Dart too:
    // queue the mouse-up before the session starts.
    events.onDragRequested =
        () => sendMacOSMouseEvent(tester.view, leftMouseUp, to, post: true);
    await _PointerInjector(tester.view).drag(from, to);
  } else {
    await _PointerInjector(tester.view).drag(from, to);
  }
}

/// testWidgets, or a skipped test with the [skip] reason (testWidgets takes
/// no reason).
void _testWidgets(String name, WidgetTesterCallback body, {String? skip}) {
  if (skip != null) {
    test(name, () {}, skip: skip);
  } else {
    testWidgets(name, body);
  }
}

Offset _center(GlobalKey key) {
  final box = key.currentContext!.findRenderObject()! as RenderBox;
  return box.localToGlobal(box.size.center(Offset.zero));
}

void main() {
  setUpBinding();
  dragAndDropTests();
}

void dragAndDropTests() {
  group('drag and drop', () {
    testWidgets('DropRegion and DragItemWidget build', (tester) async {
      final events = _Events();
      await tester.pumpWidget(_app(events));
      await tester.pumpAndSettle();
      expect(find.text('Drag me'), findsOneWidget);
      expect(find.text('Drop here'), findsOneWidget);
      // The native drop context registers the formats asynchronously.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(events.over, isEmpty);
    });

    _testWidgets('a drag session starts and ends', (tester) async {
      final events = _Events();
      await tester.pumpWidget(_app(events));
      await tester.pumpAndSettle();
      await _drag(tester, events);
      await events.started.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw StateError(
          'the drag did not start: dragItemProvider '
          '${events.session == null ? 'was not called' : 'was called'}',
        ),
      );
      final operation =
          await events.completed.future.timeout(const Duration(seconds: 20));
      debugPrint('drag ended with $operation, over: ${events.over.length}');
      expect(tester.takeException(), isNull);
      // Dropped where the cursor is (copy), or not (none).
      expect(operation, isIn([DropOperation.copy, DropOperation.none]));
    }, skip: _noDrag);

    _testWidgets('a drop delivers the item to the DropRegion', (tester) async {
      final events = _Events();
      await tester.pumpWidget(_app(events));
      await tester.pumpAndSettle();
      await _drag(tester, events);
      final operation =
          await events.completed.future.timeout(const Duration(seconds: 20));
      expect(operation, DropOperation.copy,
          reason: 'over: ${events.over.length}, enter: ${events.enter}');
      final performed =
          await events.performed.future.timeout(const Duration(seconds: 10));
      expect(performed.session.items, hasLength(1));
      expect(events.droppedLocalData, _localData);
      expect(events.droppedText, _dragText);
      expect(events.enter, greaterThan(0));
      expect(events.over, isNotEmpty);
      expect(tester.takeException(), isNull);
    }, skip: _noFullDrop);
  });
}
