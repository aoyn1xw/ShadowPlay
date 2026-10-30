import 'dart:async';
import 'dart:io';

/// One segment of a clip opened by the transport layer. Parsed response
/// metadata is kept explicit so the download engine never has to trust
/// implicit HTTP behavior.
class DownloadSegment {
  DownloadSegment({
    required this.statusCode,
    required this.body,
    required this.dispose,
    this.contentLength,
    this.contentRangeStart,
    this.contentRangeTotal,
  });

  /// 200/203/206/416 or any other HTTP status.
  final int statusCode;

  /// The (possibly empty) body for this segment. Must be fully consumed or
  /// cancelled before [dispose] is called.
  final Stream<List<int>> body;

  /// Releases the underlying connection/client after the body is consumed
  /// (or abandoned). Always safe to call once.
  final Future<void> Function() dispose;

  /// Declared byte count of THIS body. Null when the server did not send a
  /// usable Content-Length (e.g. chunked transfer).
  final int? contentLength;

  /// Start offset parsed from `Content-Range: bytes start-end/total`.
  final int? contentRangeStart;

  /// Total size parsed from `Content-Range`. Null when absent or `*`.
  final int? contentRangeTotal;

  /// The most trustworthy total size for this segment: Content-Range total
  /// wins over Content-Length (a 206 body length cannot be used as total).
  int? get declaredTotal => contentRangeTotal ?? contentLength;
}

/// Cooperative cancellation handle. Downloads check this between chunks; a
/// cancelled transfer always preserves the `.part` file for the next attempt.
class CancelToken {
  bool cancelled = false;
}

enum DownloadOutcome { success, failed, cancelled }

class DownloadResult {
  const DownloadResult.success()
      : outcome = DownloadOutcome.success,
        error = null;
  const DownloadResult.failed(this.error) : outcome = DownloadOutcome.failed;
  const DownloadResult.cancelled()
      : outcome = DownloadOutcome.cancelled,
        error = null;

  final DownloadOutcome outcome;
  final Object? error;

  String? get errorText => outcome == DownloadOutcome.failed
      ? error?.toString() ?? 'Download failed.'
      : null;
}

/// Throttles progress notifications while keeping an accurate reading of the
/// current fraction. Terminal readings are always flushed immediately.
class ProgressThrottle {
  ProgressThrottle({this.minInterval = const Duration(milliseconds: 150)});

  final Duration minInterval;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  double? _pending;

  /// Returns true when the callback should fire now.
  bool shouldEmit(double fraction, {required bool isTerminal}) {
    final now = DateTime.now();
    if (isTerminal) {
      _lastEmit = now;
      _pending = null;
      return true;
    }
    if (_lastEmit.isAfter(now)) {
      // Clock moved backwards (tests/fakes); emit a reasonable amount.
      return true;
    }
    final previous = _pending;
    _pending = fraction;
    if (previous == null) {
      return now.difference(_lastEmit) >= minInterval;
    }
    return now.difference(_lastEmit) >= minInterval ||
        (fraction - previous).abs() >= 0.01;
  }
}

/// Contract errors raised when a server misbehaves in a way that would risk
/// writing a corrupted file.
class DownloadProtocolException implements Exception {
  const DownloadProtocolException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A resumable, strictly validated download sink.
///
/// Guarantees:
///  * appends only to a `.part` file whose full prefix was verified;
///  * a server that ignores Range is handled by restarting from byte zero;
///  * no file is declared successful unless the received byte count matches
///    the expected size and the on-disk part file length matches too;
///  * the part file is preserved on network interruption or cancellation so
///    the next attempt can resume, and deleted only when its contents are
///    known to be unusable (e.g. server changed the file).
///
/// The file is NOT published here; callers mirror the verified part into its
/// final location after this returns success.
class ResumableDownloader {
  ResumableDownloader({
    required this.openSegment,
    required this.partFile,
    required this.expectedSize,
    this.onProgress,
    this.cancelToken,
    this.stallTimeout = const Duration(seconds: 60),
    this.maxServerResets = 2,
    this.progressThrottle,
  }) : assert(expectedSize > 0, 'expectedSize must be positive');

  /// Opens one segment for the given absolute start offset (null = full
  /// body). The transport decides how Range is requested.
  final Future<DownloadSegment> Function(int? rangeStart) openSegment;

  /// The `.part` file receiving bytes.
  final File partFile;

  /// Authoritative total size for the clip (from the clip catalog).
  final int expectedSize;

  final void Function(double fraction)? onProgress;
  final CancelToken? cancelToken;

  /// Fails the transfer when no bytes arrive within this window so a dead
  /// connection cannot hang the download worker forever.
  final Duration stallTimeout;

  /// How many times a misbehaving Range response may force a full restart.
  final int maxServerResets;

  final ProgressThrottle? progressThrottle;

  Future<DownloadResult> download() async {
    var resetsLeft = maxServerResets;
    while (true) {
      final result = await _attempt(resetsLeft: resetsLeft);
      if (result is _AttemptRestart) {
        resetsLeft -= 1;
        if (resetsLeft < 0) {
          return DownloadResult.failed(
            DownloadProtocolException(
              'The PC repeatedly returned inconsistent partial responses; '
              'the download could not resume safely.',
            ),
          );
        }
        // A reconsumed/reset part is unusable until the next clean segment.
        if (await partFile.exists()) {
          try {
            await partFile.delete();
          } catch (error) {
            return DownloadResult.failed(
                'Could not reset the partial download: $error');
          }
        }
        continue;
      }
      return result as DownloadResult;
    }
  }

  // ---------------------------------------------------------------- attempt

  /// Returns a [DownloadResult], or an internal [_AttemptRestart] signal.
  Future<Object> _attempt({required int resetsLeft}) async {
    // A zero-byte (or negative) expectation is never a valid target; clip
    // files are validated server-side to be non-empty.
    if (expectedSize <= 0) {
      return const DownloadResult.failed(
          DownloadProtocolException('The PC reported an invalid clip size.'));
    }

    final int resumeFrom;
    if (await partFile.exists()) {
      try {
        resumeFrom = await partFile.length();
      } catch (error) {
        return DownloadResult.failed(
            'Could not read the partial download: $error');
      }
    } else {
      resumeFrom = 0;
    }
    final hasPrefix = resumeFrom > 0;

    final DownloadSegment segment;
    try {
      segment = await openSegment(hasPrefix ? resumeFrom : null);
    } catch (error) {
      // Connection-level failure: the prefix bytes are still valid, keep them.
      return DownloadResult.failed(error);
    }

    // Local function (not a closure variable): the analyzer prefers this form,
    // and it captures only the final `segment` value.
    Future<void> disposeSegment() async {
      try {
        await segment.dispose();
      } catch (_) {}
    }

    IOSink? sink;
    try {
      final status = segment.statusCode;

      if (status == 416) {
        // Range Not Satisfiable: either the part already holds the whole
        // file, or the server lost track of it. The total is taken only from
        // Content-Range (`bytes */total`) — an empty 416 body's
        // Content-Length must not be confused with the file size.
        if (hasPrefix && resumeFrom == expectedSize) {
          final knownTotal = segment.contentRangeTotal;
          if (knownTotal != null && knownTotal != expectedSize) {
            return await _failCorrupt(
              'The PC reports a different size for this clip than when the '
              'download started.',
            );
          }
          return _verifyLocalOnly();
        }
        if (resetsLeft <= 0) {
          return const DownloadResult.failed(
            DownloadProtocolException(
                'The PC rejected the resume position and the download '
                'could not restart.'),
          );
        }
        return _restart();
      }

      if (status != 200 && status != 203 && status != 206) {
        return await _failCorrupt(
          DownloadProtocolException(
              'The PC responded with HTTP $status for the download.'),
        );
      }

      final total = segment.declaredTotal;
      if (total != null && total != expectedSize) {
        return await _failCorrupt(
          'The PC reports a different size for this clip than when the '
          'download started.',
        );
      }

      if (status == 206) {
        final start = segment.contentRangeStart;
        if (start == null) {
          // A 206 without Content-Range is invalid; the prefix bytes cannot
          // be trusted to align with this body.
          if (resetsLeft <= 0) {
            return const DownloadResult.failed(
              DownloadProtocolException(
                  'The PC returned a partial response without a byte range; '
                  'the download could not be verified.'),
            );
          }
          return _restart();
        }
        if (start != resumeFrom) {
          if (resetsLeft <= 0) {
            return const DownloadResult.failed(
              DownloadProtocolException(
                  'The PC returned a mismatched resume position; the '
                  'download could not continue safely.'),
            );
          }
          return _restart();
        }
      } else if (hasPrefix) {
        // 200/203 with a Range request means the server ignored resume; the
        // body is a full file whose first bytes must NOT be appended.
        if (resetsLeft <= 0) {
          return const DownloadResult.failed(
            DownloadProtocolException(
                'The PC ignored the resume request and the download could '
                'not restart.'),
          );
        }
        return _restart();
      }

      // ---- data phase -------------------------------------------------------
      // Bind to a non-null local: the `finally` block tracks the nullable
      // field value, but closure capture defeats promotion on `sink` itself.
      final out = partFile.openWrite(
        mode: hasPrefix ? FileMode.append : FileMode.write,
      );
      sink = out;
      var received = resumeFrom;
      await for (final chunk in segment.body.timeout(stallTimeout)) {
        if (cancelToken?.cancelled ?? false) {
          await out.flush();
          await out.close();
          sink = null;
          await disposeSegment();
          return const DownloadResult.cancelled();
        }
        out.add(chunk);
        received += chunk.length;
        if (received > expectedSize) {
          // Extra bytes mean the part is no longer a verified prefix.
          await out.close();
          sink = null;
          return await _failCorrupt(
            'The PC sent more data than the clip should contain.',
            deletePart: true,
          );
        }
        _reportProgress(received / expectedSize);
      }
      await out.flush();
      await out.close();
      sink = null;

      if (received != expectedSize) {
        // Truncated transfer: the prefix stays valid for the next resume.
        return DownloadResult.failed(
          DownloadProtocolException(
            'The PC closed the connection after $received of $expectedSize '
            'bytes. The partial download was kept and can be resumed.',
          ),
        );
      }

      // Double-checked file length before declaring success.
      return _verifyLocalOnly();
    } on DownloadProtocolException catch (error) {
      return DownloadResult.failed(error);
    } on TimeoutException {
      return const DownloadResult.failed(
        DownloadProtocolException(
            'The PC stopped sending data. The partial download was kept and '
            'can be resumed.'),
      );
    } catch (error) {
      if (cancelToken?.cancelled ?? false) {
        return const DownloadResult.cancelled();
      }
      return DownloadResult.failed(error);
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      await disposeSegment();
    }
  }

  /// Signals a clean restart; the outer loop deletes the part and retries.
  /// The unconsumed segment is closed by the `finally` block in `_attempt`.
  _AttemptRestart _restart() => const _AttemptRestart();

  DownloadResult _verifyLocalOnly() {
    try {
      // Synchronous length check: the file was closed above, so this is
      // deterministic.
      final length = partFile.lengthSync();
      if (length != expectedSize) {
        return DownloadResult.failed(
          DownloadProtocolException(
            'The finished file has $length bytes but the PC reported '
            '$expectedSize bytes.',
          ),
        );
      }
      return const DownloadResult.success();
    } catch (error) {
      return DownloadResult.failed(
          'Could not verify the finished download: $error');
    }
  }

  Future<DownloadResult> _failCorrupt(
    Object error, {
    bool deletePart = false,
  }) async {
    if (deletePart && await partFile.exists()) {
      try {
        await partFile.delete();
      } catch (_) {}
    }
    return DownloadResult.failed(error);
  }

  void _reportProgress(double fraction) {
    if (onProgress == null) return;
    final throttle = progressThrottle;
    if (throttle == null) {
      onProgress!(fraction);
      return;
    }
    if (throttle.shouldEmit(fraction, isTerminal: false)) {
      onProgress!(fraction);
    }
  }
}

/// Internal control-flow signal for restarts; never observable by callers.
class _AttemptRestart {
  const _AttemptRestart();
}
