// Verifies that x-client-transaction-id generation still works against the
// live X frontend, which it cannot be tested against in `flutter test`.
//
//   dart run tool/check_indices.dart
//
// X reshapes their frontend without notice (the 2026 x-web migration removed
// the ondemand.s chunk the generator read), and every port of this algorithm
// broke the same week. When Search and follows start answering 404, run this
// first: it says whether the generator can still find its inputs or whether the
// walk in ClientTransaction._findIndicesFileUrl needs updating again.
//
// What it cannot tell you is whether the *key* is right. X reshaping the
// loading-x-anim SVG does not throw — it produces a plausible-looking id that
// X answers 403 for, and this tool would print OK. The id's length is not a
// reliable signal either: the algorithm's output length follows the hex digits
// it derives, so a correct id is not a fixed size. Only a real request with a
// real session distinguishes a right key from a wrong one, so the output says
// exactly that instead of guessing at a length.
import 'dart:io';

import 'package:quax/client/x_client_transaction_id/client_transaction.dart';

Future<void> main() async {
  final stopwatch = Stopwatch()..start();

  try {
    final transaction = await ClientTransaction.initialize();
    final id = transaction.generateTransactionId(
        'GET', '/i/api/graphql/placeholder/SearchTimeline');

    stopwatch.stop();
    stdout.writeln('OK   ${stopwatch.elapsedMilliseconds} ms');
    final head = id.length >= 12 ? id.substring(0, 12) : id;
    stdout.writeln('id   ${id.length} base64 chars, starts $head…');
    stdout.writeln('');
    stdout.writeln('The generator found its inputs and produced an id.');
    stdout.writeln('');
    stdout.writeln('That is all this can check. A *wrong* animation key also');
    stdout.writeln('produces a well-formed id — X reshaping the loading-x-anim');
    stdout.writeln('SVG does not throw, it just derives a different one — and');
    stdout.writeln('the length is no signal either, because it follows the hex');
    stdout.writeln('digits the derivation happens to produce.');
    stdout.writeln('');
    stdout.writeln('The only reliable check is a real request:');
    stdout.writeln('  • 404 → the queryId or the endpoint moved; this header is fine.');
    stdout.writeln('  • 403 → the queryId is fine and the animation key is wrong.');
    stdout.writeln('        Compare _get2dArray/_animate against the current');
    stdout.writeln('        loading-x-anim markup on x.com/home.');
  } catch (e, stackTrace) {
    stopwatch.stop();
    stdout.writeln('FAIL ${stopwatch.elapsedMilliseconds} ms');
    stdout.writeln('$e');
    stdout.writeln('');
    stdout.writeln(stackTrace.toString().split('\n').take(6).join('\n'));
    stdout.writeln('');
    stdout.writeln('The generator cannot find its inputs. Compare the walk in');
    stdout.writeln('ClientTransaction._findIndicesFileUrl with the current build:');
    stdout.writeln(
        r'  curl -s https://x.com/home | grep -oE "https://[^"]+/x-web/[^"]+\.js"');
    exitCode = 1;
  }
}
