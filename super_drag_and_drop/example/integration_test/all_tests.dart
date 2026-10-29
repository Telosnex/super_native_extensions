// Every test of this directory in one app: one build and launch per run
// (iOS: one target, as the Telosnex CI standard asks).
import 'binding.dart';
import 'drag_and_drop_test.dart';
import 'hot_key_test.dart';

void main() {
  setUpBinding();
  dragAndDropTests();
  hotKeyTests();
}
