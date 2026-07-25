import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/widgets/resizable_split.dart';

void main() {
  testWidgets('horizontal divider drag widens the first pane + settles',
      (tester) async {
    double? settled;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 600,
          child: ResizableSplit(
            axis: Axis.horizontal,
            ratio: 0.3,
            minFirst: 100,
            minSecond: 100,
            onRatioSettled: (r) => settled = r,
            first: Container(key: const Key('first'), color: Colors.red),
            second: Container(key: const Key('second'), color: Colors.blue),
          ),
        ),
      ),
    ));
    await tester.pump();

    final before = tester.getSize(find.byKey(const Key('first'))).width;
    // The divider is the 8px strip immediately to the right of the first pane.
    await tester.dragFrom(Offset(before + 4, 300), const Offset(150, 0));
    await tester.pump();

    final after = tester.getSize(find.byKey(const Key('first'))).width;
    expect(after, greaterThan(before + 100),
        reason: 'dragging the divider right should widen the first pane');
    expect(settled, isNotNull,
        reason: 'drag-end should report the new ratio for persistence');
  });

  testWidgets('vertical divider drag grows the first pane', (tester) async {
    double? settled;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          height: 1000,
          child: ResizableSplit(
            axis: Axis.vertical,
            ratio: 0.3,
            minFirst: 100,
            minSecond: 100,
            onRatioSettled: (r) => settled = r,
            first: Container(key: const Key('top'), color: Colors.red),
            second: Container(key: const Key('bottom'), color: Colors.blue),
          ),
        ),
      ),
    ));
    await tester.pump();

    final before = tester.getSize(find.byKey(const Key('top'))).height;
    await tester.dragFrom(Offset(300, before + 4), const Offset(0, 150));
    await tester.pump();

    final after = tester.getSize(find.byKey(const Key('top'))).height;
    expect(after, greaterThan(before + 100));
    expect(settled, isNotNull);
  });

  testWidgets('respects min sizes (cannot drag past the second pane min)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 600,
          child: ResizableSplit(
            axis: Axis.horizontal,
            ratio: 0.3,
            minFirst: 100,
            minSecond: 400,
            onRatioSettled: (_) {},
            first: Container(key: const Key('first'), color: Colors.red),
            second: Container(color: Colors.blue),
          ),
        ),
      ),
    ));
    await tester.pump();

    // Drag far to the right; the first pane is capped so the second keeps >= 400.
    await tester.dragFrom(const Offset(300, 300), const Offset(900, 0));
    await tester.pump();

    final after = tester.getSize(find.byKey(const Key('first'))).width;
    // available = 1000 - 8 = 992; maxFirst = 992 - 400 = 592.
    expect(after, lessThanOrEqualTo(592 + 0.5));
  });

  testWidgets('lays out without throwing when narrower than minFirst',
      (tester) async {
    // A phone-width viewport is smaller than the browse cascade's minimums.
    // double.clamp throws when its lower limit exceeds the upper, so an
    // unguarded clamp(minFirst, avail) here left the app stuck on a blank
    // frame rather than merely looking cramped.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 120,
          height: 400,
          child: ResizableSplit(
            axis: Axis.horizontal,
            ratio: 0.4,
            minFirst: 220,
            minSecond: 320,
            onRatioSettled: (_) {},
            first: Container(key: const Key('first'), color: Colors.red),
            second: Container(key: const Key('second'), color: Colors.blue),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // The first pane takes what there is; the second collapses rather than
    // forcing an overflow.
    expect(tester.getSize(find.byKey(const Key('first'))).width,
        lessThanOrEqualTo(120));
  });

  testWidgets('lays out without throwing at zero extent', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 0,
          height: 0,
          child: ResizableSplit(
            axis: Axis.vertical,
            ratio: 0.5,
            minFirst: 80,
            minSecond: 80,
            onRatioSettled: (_) {},
            first: Container(color: Colors.red),
            second: Container(color: Colors.blue),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
