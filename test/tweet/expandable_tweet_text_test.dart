import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/_ExpandableTweetText.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    localizationsDelegates: const [
      L10n.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: L10n.delegate.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  final shortSpans = [const TextSpan(text: 'short')];
  final longSpans = [TextSpan(text: 'Lorem ipsum dolor sit amet. ' * 40)];

  testWidgets('Should open the tweet when the text is tapped', (tester) async {
    var taps = 0;

    await tester.pumpWidget(_wrap(ExpandableTweetText(
      textSpans: shortSpans,
      onTap: () => taps++,
    )));

    await tester.tap(find.text('short'));
    await tester.pump();

    expect(taps, 1,
        reason: 'The card has no tap target of its own, so opening a post from the feed depends '
            'on this callback firing on a plain tap');
  });

  testWidgets('Should not offer "show more" for text that fits', (tester) async {
    await tester.pumpWidget(_wrap(ExpandableTweetText(textSpans: shortSpans)));

    expect(find.text(L10n.of(tester.element(find.byType(ExpandableTweetText))).clickToShowMore),
        findsNothing,
        reason: 'Measuring must not claim a one-line text overflows, or every short post grows a '
            'useless button');
  });

  testWidgets('Should expand the text when "show more" is tapped', (tester) async {
    await tester.pumpWidget(_wrap(ExpandableTweetText(textSpans: longSpans, maxLines: 8)));

    final button = find.text(L10n.of(tester.element(find.byType(ExpandableTweetText))).clickToShowMore);
    expect(button, findsOneWidget,
        reason: 'A long post is clamped to 8 lines, so the reader needs the button to reveal the '
            'rest');

    expect(tester.widget<Text>(find.byType(Text).first).maxLines, 8,
        reason: 'The clamped text should start at the maximum number of lines');

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(button, findsNothing,
        reason: 'Once expanded the button has done its job and should leave');
    expect(tester.widget<Text>(find.byType(Text)).maxLines, isNull,
        reason: 'The expanded text renders without a line limit');
  });

  testWidgets('Should keep the measurement when the widget rebuilds', (tester) async {
    final key = GlobalKey();
    final spans = [TextSpan(text: 'Lorem ipsum dolor sit amet. ' * 40)];

    await tester.pumpWidget(_wrap(ExpandableTweetText(key: key, textSpans: spans)));
    await tester.pumpWidget(_wrap(ExpandableTweetText(key: key, textSpans: spans)));

    final state = key.currentState as ExpandableTweetTextState;
    expect(state.debugMeasuredTruncated, isTrue,
        reason: 'Rebuilding with the same text must reuse the first measurement; the whole point '
            'is that scrolling does not re-run the text layout');
  });
}
