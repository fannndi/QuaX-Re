import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/ui/dates.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en'));
  testWidgets('Should apply a changed absolute-timestamp setting to a mounted card', (tester) async {
    final timestamp = DateTime.utc(2026, 1, 2, 3, 4, 5);
    // The test MediaQuery defaults to the 12-hour clock, and the widget now
    // follows the device setting instead of always printing 24-hour time.
    final absolute = absoluteDateFormat12h.format(timestamp.toLocal());

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Timestamp(timestamp: timestamp, absoluteTimestamp: false)),
    ));
    expect(find.text(absolute), findsNothing,
        reason: 'The card starts in relative mode, as the setting was off when it mounted');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Timestamp(timestamp: timestamp, absoluteTimestamp: true)),
    ));

    expect(find.text(absolute), findsOneWidget,
        reason: 'Turning the setting on must reformat the cards already on screen, not only the '
            'ones built after the next scroll');
  });
}
