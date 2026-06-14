import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/main.dart';
import 'package:olivier/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());
  testWidgets('App renders with version string', (WidgetTester tester) async {
    await tester.pumpWidget(const OlivierApp());
    // The app body displays the Rust version string (e.g. "rust_lib_olivier 0.1.0")
    expect(find.textContaining('rust_lib_olivier'), findsOneWidget);
  });
}
