import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:telosnex_web_test/telosnex_web_test.dart';

/// The binding of every test file here. Call it once, first thing in main.
void setUpBinding() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  installWebTestSupport(binding);
  // Pointer data from the engine (the drag tests inject it there) reaches
  // the app, and frames that the app schedules are drawn as in a real app:
  // the drag image is a snapshot of a frame.
  binding.shouldPropagateDevicePointerEvents = true;
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
}
