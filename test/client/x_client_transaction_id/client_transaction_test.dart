import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/x_client_transaction_id/client_transaction.dart';
import 'package:quax/client/x_client_transaction_id/constants.dart';

String _home(String extraScripts) =>
    '''
<meta name="twitter-site-verification" content="${base64Encode([0, ...List.filled(15, 1)])}">
<div id="loading-x-anim-0"><svg><g>
  <path d="M0"/>
  <path d="M00000000C0 1 2 3 4 5 6 7 8 9 10 11"/>
</g></svg></div>
$extraScripts
''';

const _indices = '(x[0], 16), (x[1], 16)';

({TransactionReader read, List<String> reads}) _routedReader(
  Map<String, String> bodies,
) {
  final reads = <String>[];
  return (
    reads: reads,
    read: (uri, {abortTrigger}) async {
      reads.add(uri.toString());
      return bodies[uri.toString()] ?? '';
    },
  );
}

void main() {
  group('ClientTransaction.initialize()', () {
    test(
      'Should walk imported chunks breadth-first and visit each URL once',
      () async {
        final bodies = <String, String>{
          'https://x.com/home': _home(
            '<script src="https://abs.twimg.com/x-web/entry.js"></script>',
          ),
          'https://abs.twimg.com/x-web/entry.js':
              'import "./assets/a.js"; import "./assets/direct.js";',
          'https://abs.twimg.com/x-web/assets/a.js':
              'import "./nested/b.js"; import "./direct.js";',
          'https://abs.twimg.com/x-web/assets/direct.js':
              'import "./nested/c.js"; import "../a.js";',
          'https://abs.twimg.com/x-web/assets/nested/b.js':
              'import "./deep.js"; import "../a.js";',
          'https://abs.twimg.com/x-web/assets/nested/deep.js':
              'import "./sign.o-deep.js";',
          'https://abs.twimg.com/x-web/assets/nested/c.js':
              'import "./sign.o-wide.js";',
          'https://abs.twimg.com/x-web/assets/nested/sign.o-wide.js': _indices,
          'https://abs.twimg.com/x-web/assets/nested/sign.o-deep.js': _indices,
        };
        final reads = <String>[];

        final transaction = await ClientTransaction.initialize(
          reader: (uri, {abortTrigger}) async {
            reads.add(uri.toString());
            return bodies[uri.toString()] ?? '';
          },
        );

        expect(
          transaction.generateTransactionId('GET', '/test'),
          isNotEmpty,
          reason: 'A multi-level x-web import graph must still produce a transaction id',
        );
        expect(
          reads.indexOf('https://abs.twimg.com/x-web/assets/nested/c.js'),
          5,
          reason:
              'Discovery must be breadth-first: both depth-two chunks are fetched before '
              'anything imported by the first depth-two chunk',
        );
        expect(
          reads.where(
            (url) => url == 'https://abs.twimg.com/x-web/assets/a.js',
          ),
          hasLength(1),
          reason:
              'A cycle or duplicate import must not fetch the same chunk twice',
        );
        expect(
          reads,
          isNot(contains('https://abs.twimg.com/x-web/assets/nested/deep.js')),
          reason: 'The walk stops as soon as the first breadth-first indices file is found',
        );
      },
    );

    test('Should bound discovery depth and request count', () async {
      final bodies = <String, String>{
        'https://x.com/home': _home(
          '<script src="https://abs.twimg.com/x-web/entry.js"></script>',
        ),
        'https://abs.twimg.com/x-web/entry.js': 'import "./assets/a.js";',
        'https://abs.twimg.com/x-web/assets/a.js': 'import "./sign.o-deep.js";',
        'https://abs.twimg.com/x-web/assets/sign.o-deep.js': _indices,
      };
      final reads = <String>[];

      await expectLater(
        ClientTransaction.initialize(
          maxDepth: 1,
          requestBudget: 20,
          reader: (uri, {abortTrigger}) async {
            reads.add(uri.toString());
            return bodies[uri.toString()] ?? '';
          },
        ),
        throwsException,
        reason:
            'An indices file below the configured depth must not be fetched',
      );
      expect(
        reads,
        hasLength(2),
        reason: 'Depth one includes the home page and entry bundle, but none of their imported chunks',
      );

      reads.clear();
      await expectLater(
        ClientTransaction.initialize(
          maxDepth: 8,
          requestBudget: 2,
          reader: (uri, {abortTrigger}) async {
            reads.add(uri.toString());
            return bodies[uri.toString()] ?? '';
          },
        ),
        throwsException,
        reason: 'The request budget must stop a large or cyclic import graph',
      );
      expect(
        reads,
        hasLength(2),
        reason: 'The home page and entry bundle exhaust a two-request budget',
      );
    });

    test('Should retain the legacy ondemand fast path', () async {
      final reads = <String>[];
      final transaction = await ClientTransaction.initialize(
        reader: (uri, {abortTrigger}) async {
          reads.add(uri.toString());
          if (uri.toString() == 'https://x.com/home') {
            return _home(
              ',7:"ondemand.s",7:"abcdef",'
              '<script src="https://abs.twimg.com/x-web/entry.js"></script>',
            );
          }
          expect(
            uri.toString(),
            'https://abs.twimg.com/responsive-web/client-web/ondemand.s.abcdefa.js',
            reason: 'The legacy page hash must still resolve directly without walking chunks',
          );
          return _indices;
        },
      );

      expect(transaction.generateTransactionId('GET', '/test'), isNotEmpty);
      expect(
        reads,
        hasLength(2),
        reason: 'A legacy page costs only the home page and its directly linked indices file',
      );
    });

    test(
      'Should select the second descendant path inside a grouped SVG',
      () async {
        final transaction = await ClientTransaction.initialize(
          reader: (uri, {abortTrigger}) async {
            if (uri.toString() == 'https://x.com/home') {
              return _home(',7:"ondemand.s",7:"abcdef"');
            }
            return _indices;
          },
        );

        expect(
          transaction.generateTransactionId(
            'POST',
            '/i/api/graphql/x/HomeTimeline',
          ),
          isNotEmpty,
          reason:
              'The second path below <svg> may be nested in <g>; treating it as the second '
              'direct SVG child makes every transaction id fail to derive',
        );
      },
    );
    test(
      'Should find a hashed signing module two static import levels down',
      () async {
        const base = 'https://abs.twimg.com/x-web/x-web';
        final routes = _routedReader({
          'https://x.com/home': _home(
            '<script src="$base/entry-client-Ab1.js"></script>',
          ),
          '$base/entry-client-Ab1.js':
              'import{a as b}from"./assets/Lvl_1.js";import"./assets/Css1.js";',
          '$base/assets/Lvl_1.js':
              'function f(){return import(`./Sg_9x.js`).then(e=>e.default())}',
          '$base/assets/Css1.js': '',
          '$base/assets/Sg_9x.js': _indices,
        });

        final transaction = await ClientTransaction.initialize(
          reader: routes.read,
        );

        expect(
          transaction.generateTransactionId('GET', '/test'),
          isNotEmpty,
          reason:
              'The hashed x-web build has no sign.o filename; discovery must recognize the '
              'dynamically imported module by its signing content',
        );
        expect(routes.reads, contains('$base/assets/Sg_9x.js'));
      },
    );

    test('Should choose a dynamic candidate by content and reject one-index chunks', () async {
      const base = 'https://abs.twimg.com/x-web/x-web';
      final routes = _routedReader({
        'https://x.com/home': _home(
          '<script src="$base/entry-client-Ab1.js"></script>',
        ),
        '$base/entry-client-Ab1.js': 'import{a}from"./assets/Lvl_1.js";',
        '$base/assets/Lvl_1.js':
            'import("./One.js").then(e=>e.default());'
            "import(`./None.js`).then(n=>n.default());"
            "import('./Sign.js').then((t) => t.default());"
            'import("./Plain.js").then(e=>e.foo())',
        '$base/assets/One.js': 'x=(a[5], 16)',
        '$base/assets/None.js': 'nothing here',
        '$base/assets/Sign.js': _indices,
        '$base/assets/Plain.js': _indices,
      });

      final transaction = await ClientTransaction.initialize(
        reader: routes.read,
      );

      expect(transaction.generateTransactionId('GET', '/test'), isNotEmpty);
      expect(
        routes.reads,
        contains('$base/assets/Sign.js'),
        reason: 'A candidate needs at least two indices matches to be the signing module',
      );
      expect(
        routes.reads,
        isNot(contains('$base/assets/Plain.js')),
        reason: 'A dynamic import that does not call default() is not a signing candidate',
      );
    });

    test(
      'Should stop on a named reference before scanning dynamic candidates',
      () async {
        const base = 'https://abs.twimg.com/x-web/x-web';
        final routes = _routedReader({
          'https://x.com/home': _home(
            '<script src="$base/entry-client-Ab1.js"></script>',
          ),
          '$base/entry-client-Ab1.js': 'import("./assets/Hash1.js").then(e=>e.default());import("./sign.o-abc123.js")',
          '$base/sign.o-abc123.js': _indices,
          '$base/assets/Hash1.js': _indices,
        });

        final transaction = await ClientTransaction.initialize(
          reader: routes.read,
        );

        expect(transaction.generateTransactionId('GET', '/test'), isNotEmpty);
        expect(
          routes.reads,
          isNot(contains('$base/assets/Hash1.js')),
          reason: 'The named-reference fast path must win without downloading lazy candidates',
        );
      },
    );

    test('Should check a dynamic candidate that was preloaded by the page', () async {
      const base = 'https://abs.twimg.com/x-web/x-web';
      const sign = '$base/assets/Sg_9x.js';
      final routes = _routedReader({
        'https://x.com/home': _home(
          '<script src="$base/entry-client-Ab1.js"></script><link rel="modulepreload" href="$sign">',
        ),
        '$base/entry-client-Ab1.js':
            'import(`./assets/Sg_9x.js`).then(e=>e.default())',
        sign: _indices,
      });

      final transaction = await ClientTransaction.initialize(
        reader: routes.read,
      );

      expect(
        transaction.generateTransactionId('GET', '/test'),
        isNotEmpty,
        reason: 'An already-seen candidate may still be the signing module',
      );
      expect(routes.reads, contains(sign));
    });

    test('Should ignore a failed unrelated page script', () async {
      const base = 'https://abs.twimg.com/x-web/x-web';
      const manifest = '$base/xchat/embed/x/mf-manifest.js';
      final routes = _routedReader({
        'https://x.com/home': _home(
          '<script src="$base/entry-client-Ab1.js"></script><script src="$manifest"></script>',
        ),
        '$base/entry-client-Ab1.js': 'import{a}from"./assets/Lvl_1.js";',
        '$base/assets/Lvl_1.js': 'import(`./Sg_9x.js`).then(e=>e.default())',
        '$base/assets/Sg_9x.js': _indices,
      });

      final transaction = await ClientTransaction.initialize(
        reader: (uri, {abortTrigger}) async {
          final body = await routes.read(uri);
          if (uri.toString() == manifest) throw Exception('not found');
          return body;
        },
      );

      expect(transaction.generateTransactionId('GET', '/test'), isNotEmpty);
      expect(
        routes.reads,
        contains(manifest),
        reason: 'A failed sibling script may be attempted, but must not hide the signing chunk',
      );
    });

    test('Should follow no more than two extra static import levels', () async {
      const base = 'https://abs.twimg.com/x-web/x-web';
      final routes = _routedReader({
        'https://x.com/home': _home(
          '<script src="$base/entry-client-Ab1.js"></script>',
        ),
        '$base/entry-client-Ab1.js': 'import"./assets/L1.js";',
        '$base/assets/L1.js': 'import"./L2.js";',
        '$base/assets/L2.js': 'import"./L3.js";',
        '$base/assets/L3.js': 'import(`./Sign.js`).then(e=>e.default())',
        '$base/assets/Sign.js': _indices,
      });

      await expectLater(
        ClientTransaction.initialize(reader: routes.read),
        throwsException,
      );

      expect(
        routes.reads,
        isNot(contains('$base/assets/L3.js')),
        reason: 'A third static import hop is outside the bounded hashed-build search',
      );
      expect(routes.reads, isNot(contains('$base/assets/Sign.js')));
    });

    test('Should not wait for a stalled unrelated page asset', () async {
      const base = 'https://abs.twimg.com/x-web/x-web';
      const stalled = '$base/assets/Stalled.js';
      final stalledRead = Completer<String>();
      final routes = _routedReader({
        'https://x.com/home': _home(
          '<script src="$stalled"></script><script src="$base/entry-client-Ab1.js"></script>',
        ),
        '$base/entry-client-Ab1.js': 'import("./sign.o-abc123.js")',
        '$base/sign.o-abc123.js': _indices,
      });

      final transaction = await ClientTransaction.initialize(
        reader: (uri, {abortTrigger}) =>
            uri.toString() == stalled ? stalledRead.future : routes.read(uri),
        assetTimeout: const Duration(milliseconds: 50),
      ).timeout(const Duration(milliseconds: 500));

      expect(
        transaction.generateTransactionId('GET', '/test'),
        isNotEmpty,
        reason: 'A named reference in a sibling entry must not wait for a stalled download',
      );
    });

    test(
      'Should cancel a stalled asset read when the overall deadline expires',
      () async {
        const base = 'https://abs.twimg.com/x-web/x-web';
        final started = Completer<void>();
        final cancelled = Completer<void>();
        final routes = _routedReader({
          'https://x.com/home': _home(
            '<script src="$base/entry-client-Ab1.js"></script>',
          ),
          '$base/entry-client-Ab1.js': 'import"../Stalled.js";',
        });

        await expectLater(
          ClientTransaction.initialize(
            reader: (uri, {abortTrigger}) async {
              if (uri.path.endsWith('/Stalled.js')) {
                started.complete();
                await abortTrigger!.then((_) {
                  cancelled.complete();
                  throw TimeoutException('asset cancelled');
                });
              }
              return routes.read(uri);
            },
            deadline: DateTime.now().add(const Duration(milliseconds: 100)),
            assetTimeout: const Duration(seconds: 1),
          ).timeout(const Duration(seconds: 2)),
          throwsA(isA<TimeoutException>()),
          reason: 'The shared discovery deadline must reach every production asset request',
        );
        await expectLater(
          cancelled.future,
          completes,
          reason: 'A timed-out read must be cancelled, not merely ignored while its HTTP work continues',
        );
      },
    );

    test(
      'Should check the deadline before scheduling the next import wave',
      () async {
        const base = 'https://abs.twimg.com/x-web/x-web';
        final routes = _routedReader({
          'https://x.com/home': _home(
            '<script src="$base/entry-client-Ab1.js"></script>',
          ),
          '$base/entry-client-Ab1.js': 'import"./Never.js";',
          '$base/Never.js': 'import"./sign.o-too-late.js";',
        });

        await expectLater(
          ClientTransaction.initialize(
            reader: (uri, {abortTrigger}) async {
              if (uri.path.endsWith('/entry-client-Ab1.js')) {
                // Simulate a reader that notices cancellation only after returning.
                await Future<void>.delayed(const Duration(milliseconds: 50));
              }
              return routes.read(uri);
            },
            deadline: DateTime.now().add(const Duration(milliseconds: 20)),
            assetTimeout: const Duration(seconds: 1),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(
          routes.reads,
          isNot(contains('$base/Never.js')),
          reason: 'Once the deadline has fired, discovery must not schedule another wave',
        );
      },
    );

    test(
      'Should fetch at most 32 statically imported assets beyond page entries',
      () async {
        const base = 'https://abs.twimg.com/x-web/x-web';
        final imports = List.generate(
          33,
          (index) => 'import"./assets/$index.js";',
        ).join();
        final bodies = <String, String>{
          'https://x.com/home': _home(
            '<script src="$base/entry-client-Ab1.js"></script>',
          ),
          '$base/entry-client-Ab1.js': imports,
          for (var index = 0; index < 32; index++) '$base/assets/$index.js': '',
          '$base/assets/32.js': 'import"./sign.o-over-budget.js"',
          '$base/assets/sign.o-over-budget.js': _indices,
        };
        final routes = _routedReader(bodies);

        await expectLater(
          ClientTransaction.initialize(reader: routes.read),
          throwsException,
        );

        expect(
          routes.reads,
          isNot(contains('$base/assets/32.js')),
          reason: 'The 33rd imported asset is outside the hashed-build discovery budget',
        );
      },
    );
  });

  group('x-web import patterns', () {
    test('Should match only quoted static from/import statements', () {
      const source = '''
import{a as b}from"./assets/Lvl_1.js";
import './side.js';
import(`./dynamic.js`)
''';
      expect(
        staticImportRegex.allMatches(source).map((match) => match.group(2)),
        ['./assets/Lvl_1.js', './side.js'],
        reason: 'A dynamic import must not be followed as a static dependency',
      );
    });

    test('Should match default-export dynamic imports across quotes and whitespace', () {
      const source = '''
import("./One.js").then(e=>e.default())
import(`./Two.js`)
  .then( (module) => module.default() )
import('./Three.js').then(t=>t.foo())
''';
      expect(
        defaultImportRegex.allMatches(source).map((match) => match.group(2)),
        ['./One.js', './Two.js'],
        reason: 'Only import(path).then(module => module.default()) loads the signing module',
      );
    });
  });
}
