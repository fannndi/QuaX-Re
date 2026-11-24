import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quax/profile/profile.dart';

void main() {
  testWidgets(
    'Should move the active inner profile list before the outer header',
    (tester) async {
      final inner = ScrollController();
      final outer = ScrollController();
      addTearDown(inner.dispose);
      addTearDown(outer.dispose);
      final order = <String>[];
      inner.addListener(() {
        if (inner.hasClients && inner.positions.first.pixels == 0) {
          order.add('inner');
        }
      });
      outer.addListener(() {
        if (outer.hasClients && outer.positions.first.pixels == 0) {
          order.add('outer');
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    controller: outer,
                    itemExtent: 40,
                    itemCount: 100,
                    itemBuilder: (_, _) => const SizedBox.expand(),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: inner,
                    itemExtent: 40,
                    itemCount: 100,
                    itemBuilder: (_, _) => const SizedBox.expand(),
                  ),
                ),
              ],
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: () => scrollProfileToTop(inner, outer),
              child: const Icon(Icons.arrow_upward),
            ),
          ),
        ),
      );

      inner.jumpTo(640);
      outer.jumpTo(320);
      order.clear();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();

      expect(
        order,
        ['inner', 'outer'],
        reason:
            'Scrolling only the outer nested controller collapses the header but leaves '
            'the active tweet/media list exactly where the reader left it',
      );
      expect(
        inner.offset,
        0,
        reason: 'The inner list is the reader\'s actual timeline position',
      );
      expect(
        outer.offset,
        0,
        reason:
            'After the inner list reaches the top, the header must also expand',
      );
    },
  );
}
