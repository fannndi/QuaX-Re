import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/utils/rich_text.dart';

void main() {
  testWidgets('Should map entity indices by code point, not UTF-16', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (builderContext) {
        context = builderContext;
        return const SizedBox();
      }),
    ));

    // The emoji is one rune but two UTF-16 code units. X's indices count the
    // former; a substring-based implementation would start the link one
    // character early and break every URL after an emoji.
    const text = '🙂 https://t.co/abc';
    final parts = buildRichText(context, text, {
      'urls': [
        {
          'url': 'https://t.co/abc',
          'expanded_url': 'https://example.com/article',
          'display_url': 'example.com/article',
          'indices': [2, 18],
        }
      ],
    });

    expect(parts.first.plainText, '🙂 ',
        reason: 'The text before the link must keep the emoji and the space, exactly as X counted them');
    final link = parts[1].entity as TextSpan;
    expect(link.text, 'example.com/article',
        reason: 'The URL entity must be built from the entity at [2, 18], not from a UTF-16 slice');
  });
}
