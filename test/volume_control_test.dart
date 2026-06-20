import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/volume.dart';
import 'package:olivier/widgets/volume_control.dart';

void main() {
  testWidgets('VolumeControl reflects the provider and drives setVolume',
      (tester) async {
    final applied = <double>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => '0.3'),
        setSettingFnProvider.overrideWithValue((key, value) async {}),
        setVolumeFnProvider.overrideWithValue((v) async => applied.add(v)),
      ],
      child: const MaterialApp(home: Scaffold(body: VolumeControl())),
    ));
    await tester.pumpAndSettle();

    // Reflects the loaded 0.3 and shows the low-volume icon (< 0.5).
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0.3);
    expect(find.byIcon(Icons.volume_down), findsOneWidget);

    // Dragging right drives setVolume to a higher value.
    await tester.drag(find.byType(Slider), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(applied, isNotEmpty);
    expect(applied.last, greaterThan(0.3));
  });
}
