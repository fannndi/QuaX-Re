import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quax/utils/rich_text.dart';

void main() {
  Future<List<RichTextPart>> buildRich(
    WidgetTester tester,
    String text,
    Object? entities,
  ) async {
    late List<RichTextPart> parts;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            parts = buildRichText(context, text, entities);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return parts;
  }

  // 'https://t.co/xyz' is 16 code units and '🎉 nice ' is 8, so the t.co link
  // sits at code-unit offsets [8, 24] in every fixture below.
  final urlEntities = {
    'urls': [
      {
        'url': 'https://t.co/xyz',
        'expanded_url': 'https://example.com/',
        'display_url': 'example.com',
        'indices': [8, 24],
      },
    ],
  };

  group('buildRichText()', () {
    testWidgets(
      'Should slice entity indices by UTF-16 code units, not code points',
      (tester) async {
        final parts = await buildRich(
          tester,
          '🎉 nice https://t.co/xyz',
          urlEntities,
        );

        expect(
          parts.length,
          2,
          reason: 'The text before the link and the link itself should be the only parts',
        );
        expect(
          parts[0].plainText,
          '🎉 nice ',
          reason:
              'The 🎉 emoji is 2 code units but 1 code point, so a rune-based slice would '
              'swallow the "h" of the link into this plain part and shift the rest',
        );
        expect(
          parts[0].entity,
          isNull,
          reason: 'The leading text must stay a plain text part',
        );
        expect(
          (parts[1].entity as TextSpan).text,
          'example.com',
          reason:
              'The link must keep its display text, it is what the user reads',
        );
        expect(
          parts[1].plainText,
          isNull,
          reason: 'An entity part carries the span, not plain text',
        );
      },
    );

    testWidgets('Should keep the whole text plain when it has no entities', (
      tester,
    ) async {
      final parts = await buildRich(tester, '🎉🎉 plain text', null);

      expect(
        parts.length,
        1,
        reason: 'Without entities there is nothing to split on',
      );
      expect(
        parts[0].plainText,
        '🎉🎉 plain text',
        reason: 'Astral characters alone must not break the rendering',
      );
    });

    testWidgets(
      'Should degrade an entity whose indices point past the text to plain text',
      (tester) async {
        final parts = await buildRich(tester, 'hello', {
          'urls': [
            {
              'url': 'https://t.co/xyz',
              'expanded_url': 'https://example.com/',
              'display_url': 'example.com',
              'indices': [50, 60],
            },
          ],
        });

        expect(
          parts.length,
          1,
          reason: 'An entity that lies outside the text cannot be rendered',
        );
        expect(
          parts[0].plainText,
          'hello',
          reason: 'The raw text must survive instead of throwing or being swallowed by the link',
        );
      },
    );

    testWidgets('Should drop entities with inverted indices', (tester) async {
      final parts = await buildRich(tester, 'hello world', {
        'urls': [
          {
            'url': 'https://t.co/xyz',
            'expanded_url': 'https://example.com/',
            'display_url': 'example.com',
            'indices': [10, 5],
          },
        ],
      });

      expect(
        parts.length,
        1,
        reason: 'A start after the end cannot describe a span',
      );
      expect(
        parts[0].plainText,
        'hello world',
        reason: 'Inverted indices must not cut characters out of the text',
      );
    });
  });
}
