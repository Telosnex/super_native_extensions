import 'dart:ui';

/// No AppKit off macOS.
bool get canSendMacOSEvents => false;

const leftMouseDown = 1;
const leftMouseUp = 2;
const leftMouseDragged = 6;

void sendMacOSMouseEvent(FlutterView view, int type, Offset position,
        {bool post = false}) =>
    throw UnsupportedError('AppKit events on macOS only');
