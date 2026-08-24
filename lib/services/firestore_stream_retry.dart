import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

Stream<T> resilientFirestoreStream<T>({
  required Stream<T> Function() streamFactory,
  Duration initialDelay = const Duration(milliseconds: 500),
  Duration maxDelay = const Duration(seconds: 10),
  int maxAttempts = 5,
  bool Function(Object error)? shouldRetry,
}) async* {
  var attempt = 0;

  while (attempt <= maxAttempts) {
    try {
      await for (final value in streamFactory()) {
        yield value;
      }
      return;
    } catch (error, stackTrace) {
      final retryableByDefault = error is FirebaseException
          ? _isRetryableFirebaseError(error)
          : false;
      final retryableByCustom = shouldRetry?.call(error) ?? false;
      final canRetry =
          attempt < maxAttempts && (retryableByDefault || retryableByCustom);

      if (!canRetry) {
        debugPrint('[FIRESTORE_STREAM_FATAL] $error\n$stackTrace');
        rethrow;
      }

      await _waitBeforeRetry(attempt, initialDelay, maxDelay);
      attempt += 1;
    }
  }
}

bool _isRetryableFirebaseError(FirebaseException error) {
  final code = error.code;
  return code == 'unavailable' ||
      code == 'deadline-exceeded' ||
      code == 'internal' ||
      code == 'resource-exhausted' ||
      code == 'network-request-failed' ||
      code == 'aborted';
}

Future<void> _waitBeforeRetry(
  int attempt,
  Duration initialDelay,
  Duration maxDelay,
) async {
  final delayMs = (initialDelay.inMilliseconds * (1 << attempt)).clamp(
    0,
    maxDelay.inMilliseconds,
  );
  await Future<void>.delayed(Duration(milliseconds: delayMs));
}

Future<void> configureFirestorePersistence() async {
  try {
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
  } catch (error) {
    debugPrint('[FIRESTORE_PERSISTENCE] $error');
  }
}
