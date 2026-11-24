import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/tweet/tweet.dart';

TweetWithCard tweet({String? text, String? fullText, String? noteText}) =>
    TweetWithCard()
      ..text = text
      ..fullText = fullText
      ..noteText = noteText;

void main() {
  group('tweetTextFor()', () {
    test('Should share the same long note text that the card displays', () {
      final post = tweet(
        text: 'short preview',
        fullText: 'legacy body',
        noteText: 'the complete note',
      );

      expect(
        tweetTextFor(post),
        'the complete note',
        reason:
            'Sharing a long post must not fall back to its truncated preview just because '
            'the footer used the legacy full_text field',
      );
    });

    test('Should fall back through full text to the preview', () {
      expect(
        tweetTextFor(tweet(text: 'preview', fullText: 'full body')),
        'full body',
        reason:
            'Regular long posts still use full_text when there is no note body',
      );
      expect(
        tweetTextFor(tweet(text: 'preview')),
        'preview',
        reason: 'A post without full_text still has its ordinary text to share',
      );
    });

    test(
      'Should resolve the retweeted post rather than the retweet wrapper',
      () {
        final retweet = tweet(text: 'RT @author: old preview')
          ..retweetedStatusWithCard = tweet(
            text: 'old preview',
            noteText: 'original note',
          );

        expect(
          tweetTextFor(retweet),
          'original note',
          reason:
              'The card displays the original post, so every share option must use that '
              'same body instead of the retweet wrapper',
        );
      },
    );
  });
}
