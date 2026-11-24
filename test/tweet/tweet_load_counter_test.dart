import 'package:flutter_test/flutter_test.dart';
import 'package:quax/tweet/tweet_load_counter.dart';

void main() {
  test('TweetLoadCounter Should preserve the loader callback contract', () {
    final counter = TweetLoadCounter();
    int Function() get = counter.get;
    void Function() increment = counter.increment;
    void Function() reset = counter.reset;

    expect(get(), 0, reason: 'A new page loader starts with no decoded tweets');
    increment();
    increment();
    expect(
      get(),
      2,
      reason: 'The parser reports each decoded tweet through the increment callback',
    );
    reset();
    expect(
      get(),
      0,
      reason: 'A new cursor chain must reset the parser counter',
    );
  });
}
