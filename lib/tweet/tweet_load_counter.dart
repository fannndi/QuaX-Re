/// Mutable counter shared with the tweet parser through its get/increment/reset
/// callbacks. Keeping the contract in one place prevents the home and profile
/// loaders from drifting apart.
class TweetLoadCounter {
  int _value = 0;

  int get() => _value;

  void increment() => _value++;

  void reset() => _value = 0;
}
