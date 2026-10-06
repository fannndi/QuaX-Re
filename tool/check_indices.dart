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
    stdout.writeln('id   ${id.length} base64 chars, starts ${id.substring(0, 12)}…');
    stdout.writeln('');
    stdout.writeln('The generator found its inputs. If Search still 404s, the');
    stdout.writeln('problem is the queryId or the endpoint, not this header.');
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
