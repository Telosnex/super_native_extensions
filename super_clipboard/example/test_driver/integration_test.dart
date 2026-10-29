import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:telosnex_web_test/driver.dart';

/// Grants the page the clipboard permissions through the WebDriver session
/// of flutter drive (W3C Permissions: Set Permission). Browsers under
/// automation deny them otherwise. The tests wait for the grant
/// (integration_test/clipboard_permission_web.dart).
Future<void> _grantClipboardPermissions() async {
  final uri = Platform.environment['DRIVER_SESSION_URI'];
  final id = Platform.environment['DRIVER_SESSION_ID'];
  if (uri == null || id == null) {
    stdout.writeln('No WebDriver session: clipboard permissions not granted.');
    return;
  }
  final base = Uri.parse(uri.endsWith('/') ? uri : '$uri/');
  final client = HttpClient();
  try {
    for (final name in ['clipboard-read', 'clipboard-write']) {
      // Until the page has left about:blank: an opaque origin gets none.
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (true) {
        final response = await _post(
          client,
          base.resolve('session/$id/permissions'),
          {
            'descriptor': {'name': name},
            'state': 'granted',
          },
        );
        if (response.status == 200) {
          stdout.writeln('Granted $name.');
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          stdout.writeln(
              'Could not grant $name: ${response.status} ${response.body}');
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  } finally {
    client.close();
  }
}

class _Response {
  _Response(this.status, this.body);

  final int status;
  final String body;
}

Future<_Response> _post(HttpClient client, Uri uri, Object json) async {
  final request = await client.postUrl(uri);
  final body = utf8.encode(jsonEncode(json));
  // chromedriver ignores a chunked body.
  request.headers.contentType = ContentType.json;
  request.contentLength = body.length;
  request.add(body);
  final response = await request.close();
  final answer = await response.transform(utf8.decoder).join();
  return _Response(response.statusCode, answer.split('\n').first);
}

Future<void> main() async {
  // The page loads while the driver connects: grant meanwhile.
  unawaited(_grantClipboardPermissions());
  await webIntegrationDriver();
}
