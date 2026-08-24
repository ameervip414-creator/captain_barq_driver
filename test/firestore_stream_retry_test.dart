import 'package:flutter_test/flutter_test.dart';
import 'package:captain_barq_driver/services/firestore_stream_retry.dart';

void main() {
  test(
    'retries transient stream failures before emitting the successful result',
    () async {
      var attempts = 0;

      final stream = resilientFirestoreStream<int>(
        streamFactory: () {
          attempts += 1;
          if (attempts == 1) {
            return Stream<int>.fromFuture(
              Future.error(Exception('network unavailable')),
            );
          }
          return Stream<int>.value(42);
        },
        initialDelay: Duration.zero,
        maxDelay: Duration.zero,
        maxAttempts: 2,
        shouldRetry: (error) =>
            error.toString().contains('network unavailable'),
      );

      expect(await stream.first, 42);
      expect(attempts, 2);
    },
  );
}
