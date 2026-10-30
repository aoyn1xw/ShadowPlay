import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

enum DiagnosticSeverity { debug, info, warning, error }

extension DiagnosticSeverityName on DiagnosticSeverity {
  String get label => switch (this) {
        DiagnosticSeverity.debug => 'debug',
        DiagnosticSeverity.info => 'info',
        DiagnosticSeverity.warning => 'warn',
        DiagnosticSeverity.error => 'error',
      };
}

/// One structured diagnostic event. All fields are redacted when the entry is
/// created; encoded lines are safe to share verbatim.
class DiagnosticEntry {
  const DiagnosticEntry({
    required this.timeUtc,
    required this.severity,
    required this.component,
    required this.message,
    this.context = const {},
  });

  final DateTime timeUtc;
  final DiagnosticSeverity severity;
  final String component;
  final String message;
  final Map<String, String> context;

  /// Truncation caps keep one bad caller from flooding the log file.
  static const maxMessageLength = 1600;
  static const maxContextValueLength = 400;

  factory DiagnosticEntry.create({
    required DateTime timeUtc,
    required DiagnosticSeverity severity,
    required String component,
    required String message,
    Map<String, Object?>? context,
  }) {
    final trimmed = component.trim().toLowerCase();
    final safeComponent =
        trimmed.isEmpty || trimmed.length > 24 ? 'app' : trimmed;
    return DiagnosticEntry(
      timeUtc: timeUtc,
      severity: severity,
      component: safeComponent,
      message: redact(_truncate(message, maxMessageLength)),
      context: {
        if (context != null)
          for (final entry in context.entries)
            entry.key: _contextValue(entry.key, entry.value),
      },
    );
  }

  static String _contextValue(String key, Object? value) {
    if (value == null) return 'null';
    if (isSensitiveContextKey(key)) return '●●●';
    return redact(_truncate(value.toString(), maxContextValueLength));
  }

  static String _truncate(String text, int limit) {
    if (text.length <= limit) return text;
    return '${text.substring(0, limit)}…';
  }

  /// Encoded as one JSON object per line (JSON Lines).
  String encode() => jsonEncode(<String, Object?>{
        'ts': timeUtc.toIso8601String(),
        'lv': severity.label,
        'c': component,
        'm': message,
        if (context.isNotEmpty) 'ctx': context,
      });

  /// Defensive parser: unknown or corrupt lines are skipped, never thrown.
  static DiagnosticEntry? tryParse(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) return null;
      final severity = switch (decoded['lv']) {
        'debug' => DiagnosticSeverity.debug,
        'warn' => DiagnosticSeverity.warning,
        'error' => DiagnosticSeverity.error,
        'info' => DiagnosticSeverity.info,
        _ => null,
      };
      if (severity == null) return null;
      final timestamp = DateTime.tryParse('${decoded['ts']}');
      if (timestamp == null) return null;
      final component = decoded['c'];
      final message = decoded['m'];
      if (component is! String || message is! String) return null;
      final context = decoded['ctx'];
      final values = <String, String>{};
      if (context is Map<String, dynamic>) {
        context.forEach((key, value) {
          if (value is String) values[key] = value;
        });
      }
      return DiagnosticEntry(
        timeUtc: timestamp.toUtc(),
        severity: severity,
        component: component,
        message: message,
        context: values,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => context.isEmpty
      ? '$timeUtc ${severity.label} [$component] $message'
      : '$timeUtc ${severity.label} [$component] $message $context';
}

// --------------------------------------------------------------- redaction

const _redacted = '●●●';

/// True when a context key names a secret and its value must be dropped.
/// Matching is intentionally explicit so verbose keys such as `errorCode`
/// are never redacted.
bool isSensitiveContextKey(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp(r'[-_ .]'), '');
  const secrets = <String>[
    'authorization',
    'proxyauthorization',
    'token',
    'bearertoken',
    'accesstoken',
    'pairingcode',
    'paircode',
    'passcode',
    'password',
    'passphrase',
    'secret',
    'privatekey',
  ];
  return secrets.any(normalized.contains);
}

/// Multi-line PEM blocks, including private keys and certificates.
/// Dart RegExp follows ECMAScript: inline `(?i)` flags are invalid, so
/// case-insensitivity is passed per constructor.
final RegExp _pemBlock = RegExp(
  r'-----BEGIN[ -]*(?:CERTIFICATE|PRIVATE KEY|RSA (?:CIPHER )?PRIVATE KEY'
  r'|RSA PUBLIC KEY|EC PRIVATE KEY|DSA PRIVATE KEY|OPENSSH PRIVATE KEY'
  r'|ENCRYPTED PRIVATE KEY)[ -]*-----[\s\S]*?-----END[ -]*[A-Z ()]*-----',
  caseSensitive: false,
);

final RegExp _bearerScheme =
    RegExp(r'\bbearer\s+[A-Za-z0-9._~+/\-]{6,}', caseSensitive: false);

final RegExp _authHeader = RegExp(
  r'("(?:proxy[-_ ]?)?authorization"?\s*[:=]\s*"?)[A-Za-z0-9._~+/\-]{6,}',
  caseSensitive: false,
);

final RegExp _pairingCodeValue = RegExp(
  r'(pairing[-_ ]?(?:code|pin)"?\s*[:=]\s*"?)([A-Z0-9]{4}(?:[- ]?[A-Z0-9]{3,6}){1,4})',
  caseSensitive: false,
);

final RegExp _tokenValue = RegExp(
  r'(((?:access|api|auth|bearer|pairing|device|session|refresh)[-_ ]?)?'
  r'token"?\s*[:=]\s*"?)[A-Za-z0-9._~+/\-]{6,}',
  caseSensitive: false,
);

/// Private absolute filesystem paths (Windows drive paths and POSIX private
/// roots). The file name stays visible — enough for troubleshooting.
final RegExp _privatePath = RegExp(
  r'[A-Za-z]:[\\/](?:[\w .()@\-~]*[\\/])*[\w .()@\-~]+'
  r'|(?:/(?:data|storage|mnt|proc|home|root|private|Users|tmp|var|Library'
  r'|usr)[\w /.*()@\-~]*/?[\w.()@\-~]*)',
);

/// Removes secrets and private paths from free-form text. Applied to every
/// message and context value before it is ever stored.
String redact(String text) {
  var result = text;
  final pem = _pemBlock.firstMatch(result);
  if (pem != null) {
    // The placeholder must stay single-line to preserve JSON structure.
    result = result.replaceRange(
        pem.start, pem.end, ' $_redacted key or certificate $_redacted');
  }
  result = result.replaceAllMapped(_bearerScheme, (_) => 'Bearer $_redacted');
  result =
      result.replaceAllMapped(_authHeader, (m) => '${m.group(1)}$_redacted');
  result = result.replaceAllMapped(
      _pairingCodeValue, (m) => '${m.group(1)}$_redacted');
  result =
      result.replaceAllMapped(_tokenValue, (m) => '${m.group(1)}$_redacted');
  result = result.replaceAllMapped(_privatePath, (match) {
    final raw = match.group(0)!;
    final base =
        raw.replaceAll(RegExp(r'[\\/]+$'), '').split(RegExp(r'[\\/]')).last;
    return '…/$base';
  });
  return result;
}

/// Keeps only the file name of a path so callers never pass full private
/// paths into context values in the first place.
String fileNameOf(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? path : normalized.substring(index + 1);
}

/// Short id for context values: clip and server ids are hashes; the prefix
/// is enough to correlate rows without exposing the full identifier.
String shortId(String id) => id.length > 8 ? id.substring(0, 8) : id;

// ---------------------------------------------------------------- service

/// Lightweight local diagnostics for the mobile app.
///
/// * Events are structured JSON lines held in a small in-memory ring and
///   appended to two rotating files inside one app-private directory.
/// * Writes are batched and asynchronous; call sites never wait on IO.
/// * Only `verbose` mode records [DiagnosticSeverity.debug] events.
/// * Files stay on the device. [exportReport] builds a shareable text file
///   from data already stored locally.
/// * Without [attach] the service buffers in memory only, which keeps unit
///   tests hermetic and allows startup logging before the filesystem is
///   ready.
class Diagnostics {
  Diagnostics({int memoryCapacity = 400, DateTime Function()? clock})
      : _memoryCapacity = memoryCapacity,
        _clock = clock ?? (() => DateTime.now().toUtc()),
        assert(memoryCapacity >= 10);

  final DateTime Function() _clock;
  final int _memoryCapacity;

  /// Rotated pair produced while logging: the active file and its previous
  /// generation. Both live inside one app-private directory.
  static const currentFileName = 'diagnostics.log';
  static const archiveFileName = 'diagnostics.1.log';
  static const directoryName = 'diagnostics';
  static const defaultTotalBytes = 10 * 1024 * 1024;

  Directory? _directory;
  int _maxTotalBytes = defaultTotalBytes;
  int _perFileBytes = defaultTotalBytes ~/ 2;
  int _currentSize = 0;
  int _archiveSize = 0;

  final ListQueue<DiagnosticEntry> _buffer = ListQueue<DiagnosticEntry>();
  var _pendingLines = <String>[];
  Future<void>? _drainFuture;
  Timer? _flushTimer;

  bool _verbose = false;
  int _writeFailures = 0;
  String? _lastWriteError;

  bool get verbose => _verbose;
  bool get attached => _directory != null;
  int get inMemoryCount => _buffer.length;
  int get writeFailures => _writeFailures;
  String? get lastWriteError => _lastWriteError;
  int get maxTotalBytes => _maxTotalBytes;
  int get storageBytes => attached ? _currentSize + _archiveSize : 0;

  // ------------------------------------------------------------------ modes

  /// Applies the verbose switch from settings at startup or when changed by
  /// the user. Mode changes are recorded so exported reports show them.
  void applyVerbose(bool value) {
    final changed = _verbose != value;
    _verbose = value;
    if (changed) {
      _enqueue(
        DiagnosticSeverity.info,
        'diagnostics',
        value ? 'Verbose diagnostics enabled' : 'Verbose diagnostics disabled',
      );
    }
  }

  // ------------------------------------------------------------- recording

  void debug(String component, String message, [Map<String, Object?>? ctx]) =>
      _enqueue(DiagnosticSeverity.debug, component, message, ctx);

  void info(String component, String message, [Map<String, Object?>? ctx]) =>
      _enqueue(DiagnosticSeverity.info, component, message, ctx);

  void warning(String component, String message, [Map<String, Object?>? ctx]) =>
      _enqueue(DiagnosticSeverity.warning, component, message, ctx);

  void error(String component, String message, [Map<String, Object?>? ctx]) =>
      _enqueue(DiagnosticSeverity.error, component, message, ctx);

  /// Newest-first view for the Diagnostics screen.
  List<DiagnosticEntry> recent({int limit = 200}) {
    final entries = _buffer.toList(growable: false);
    if (entries.length <= limit) return entries.reversed.toList();
    return entries.sublist(entries.length - limit).reversed.toList();
  }

  void _log(DiagnosticSeverity severity, String component, String message) =>
      _enqueue(severity, component, message, null);

  void _enqueue(
    DiagnosticSeverity severity,
    String component,
    String message, [
    Map<String, Object?>? context,
  ]) {
    if (severity == DiagnosticSeverity.debug && !_verbose) return;
    final entry = DiagnosticEntry.create(
      timeUtc: _clock(),
      severity: severity,
      component: component,
      message: message,
      context: context,
    );
    _buffer.addLast(entry);
    while (_buffer.length > _memoryCapacity) {
      _buffer.removeFirst();
    }
    if (attached) {
      _pendingLines.add(entry.encode());
      if (_pendingLines.length >= 32) {
        unawaited(flush());
      } else {
        _scheduleFlush();
      }
    }
  }

  // ------------------------------------------------------------ persistence

  /// Opens a directory for file-backed logging. Called once during startup.
  /// Entries recorded before this call are flushed into the fresh file.
  Future<void> attach(
    Directory directory, {
    int maxTotalBytes = defaultTotalBytes,
  }) async {
    _maxTotalBytes = maxTotalBytes < 8192 ? 8192 : maxTotalBytes;
    _perFileBytes = _maxTotalBytes ~/ 2;
    try {
      await directory.create(recursive: true);
    } catch (_) {}
    final preAttach = _buffer.toList();
    _pendingLines
      ..clear()
      ..addAll(preAttach.map((entry) => entry.encode()));
    _directory = directory;
    _currentSize = await _fileSize(currentFile);
    _archiveSize = await _fileSize(archiveFile);
    await flush();
    final restored = await _loadRecentFromFiles();
    _buffer
      ..clear()
      ..addAll(restored);
    while (_buffer.length > _memoryCapacity) {
      _buffer.removeFirst();
    }
  }

  /// Default production location: `<app documents>/diagnostics`.
  Future<void> attachDefault() async {
    try {
      final documents = await getApplicationDocumentsDirectory();
      await attach(Directory(
          '${documents.path}${Platform.pathSeparator}$directoryName'));
    } catch (_) {
      _writeFailures++;
      _lastWriteError = 'diagnostics storage unavailable';
    }
  }

  File get currentFile {
    final directory = _directory;
    if (directory == null) {
      throw StateError('Diagnostics storage is not attached');
    }
    return File('${directory.path}${Platform.pathSeparator}$currentFileName');
  }

  File get archiveFile {
    final directory = _directory;
    if (directory == null) {
      throw StateError('Diagnostics storage is not attached');
    }
    return File('${directory.path}${Platform.pathSeparator}$archiveFileName');
  }

  static Future<int> _fileSize(File file) async {
    try {
      final stat = await file.stat();
      return stat.size;
    } catch (_) {
      return 0;
    }
  }

  void _scheduleFlush() {
    if (!attached) return;
    _flushTimer ??= Timer(const Duration(milliseconds: 750), () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  /// Appends queued lines to disk, rotating files when the current file
  /// reaches half of the configured total budget. Safe to call concurrently;
  /// only one drain writes at a time.
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    while (_directory != null && _pendingLines.isNotEmpty) {
      final inFlight = _drainFuture;
      if (inFlight != null) {
        await inFlight;
        continue;
      }
      _drainFuture = _drainOnce();
      try {
        await _drainFuture;
      } finally {
        _drainFuture = null;
      }
    }
    // A concurrent flush may already own the final batch and still be
    // writing it; await that live drain so callers observe the finished
    // write (and any rotation it performs).
    final inFlight = _drainFuture;
    if (inFlight != null) {
      await inFlight;
    }
  }

  Future<void> _drainOnce() async {
    final batch = List.of(_pendingLines);
    _pendingLines = <String>[];
    if (batch.isEmpty) return;
    // Write in chunks bounded by the per-file budget including what is
    // already in the current file, so one huge queued batch can never blow
    // a single rotated file past that budget. Worst case overlap is one
    // very long line.
    var chunk = StringBuffer();
    var chunkBytes = 0;
    try {
      for (final line in batch) {
        final lineBytes = utf8.encode('$line\n').length;
        if (chunkBytes > 0 &&
            _currentSize + chunkBytes + lineBytes > _perFileBytes) {
          await _writeChunk(chunk.toString(), chunkBytes);
          chunk = StringBuffer();
          chunkBytes = 0;
          await _rotateNow();
        }
        chunk.write('$line\n');
        chunkBytes += lineBytes;
      }
      await _writeChunk(chunk.toString(), chunkBytes);
    } catch (error) {
      _writeFailures++;
      _lastWriteError = redact('$error');
    }
  }

  Future<void> _writeChunk(String text, int bytes) async {
    if (text.isEmpty) return;
    await currentFile.writeAsString(text, mode: FileMode.append);
    _currentSize += bytes;
    await _rotateIfNeeded();
  }

  Future<void> _rotateNow() async {
    try {
      await archiveFile.delete();
    } catch (_) {}
    try {
      await currentFile.rename(archiveFile.path);
      _archiveSize = _currentSize;
      _currentSize = 0;
    } catch (error) {
      // A rename failure (very rare) must never grow storage without
      // bound: truncate the current file instead and keep going.
      _writeFailures++;
      _lastWriteError = redact('$error');
      _currentSize = 0;
      try {
        await currentFile.delete();
      } catch (_) {}
    }
  }

  Future<void> _rotateIfNeeded() async {
    while (_currentSize >= _perFileBytes) {
      await _rotateNow();
    }
  }

  /// Reads the newest lines of archive+current files into memory so the
  /// in-app viewer keeps context across restarts.
  Future<List<DiagnosticEntry>> _loadRecentFromFiles() async {
    final lines = <String>[];
    for (final file in [archiveFile, currentFile]) {
      lines.addAll(await _tailLines(file, maxBytes: 64 * 1024));
    }
    final entries = <DiagnosticEntry>[];
    for (final line in lines) {
      final parsed = DiagnosticEntry.tryParse(line);
      if (parsed != null) entries.add(parsed);
    }
    return entries;
  }

  Future<List<String>> _tailLines(File file, {required int maxBytes}) async {
    try {
      if (!await file.exists()) return const <String>[];
      final length = await file.length();
      final start = length > maxBytes ? length - maxBytes : 0;
      final raf = await file.open();
      try {
        await raf.setPosition(start);
        final bytes = await raf.read(length - start);
        // allowMalformed keeps a torn line (interrupted write) harmless.
        final text = utf8.decode(bytes, allowMalformed: true);
        final lines = text.split('\n');
        if (start > 0 && lines.length > 1) lines.removeAt(0);
        return lines.where((line) => line.trim().isNotEmpty).toList();
      } finally {
        await raf.close();
      }
    } catch (_) {
      return const <String>[];
    }
  }

  // ------------------------------------------------------------ maintenance

  /// Deletes all stored log files and the in-memory buffer. The verbosity
  /// setting is preserved; logging continues from a fresh file.
  Future<void> clear() async {
    _pendingLines = <String>[];
    _buffer.clear();
    final directory = _directory;
    if (directory != null) {
      try {
        await currentFile.delete();
      } catch (_) {}
      try {
        await archiveFile.delete();
      } catch (_) {}
      _currentSize = 0;
      _archiveSize = 0;
    }
    _log(DiagnosticSeverity.info, 'diagnostics', 'Diagnostic logs cleared');
    await flush();
  }

  /// Exports a shareable text report. The report contains only data already
  /// stored on the device (redacted at write time) plus a static header.
  /// Sharing requires the user to send the file onward.
  Future<String> exportReport() async {
    await flush();
    final report = StringBuffer();
    _writeHeader(report);
    if (attached) {
      await _appendSection(report, archiveFile, 'Previous log file',
          maxBytes: 192 * 1024);
      await _appendSection(report, currentFile, 'Current log file',
          maxBytes: 192 * 1024);
      if (Platform.isIOS) {
        await appendHighFrameRateReports(report, _directory!.parent.path);
      }
    } else {
      report
        ..writeln()
        ..writeln('== In-memory session events ==')
        ..writeln('(file storage is unavailable on this device)');
      for (final entry in _buffer) {
        report.writeln(entry.encode());
      }
    }
    final temporary = await Directory.systemTemp.createTemp('shadowplay-');
    final file =
        File('${temporary.path}${Platform.pathSeparator}shadowplay-diagnostics-'
            '${_clock().millisecondsSinceEpoch}.txt');
    await file.writeAsString(report.toString(), flush: true);
    return file.path;
  }

  void _writeHeader(StringBuffer report) {
    report
      ..writeln('ShadowPlay Diagnostics Report')
      ..writeln('generated (UTC): ${_clock().toIso8601String()}')
      ..writeln('app: ShadowPlay mobile 0.1.0 (1)')
      ..writeln(
          'platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('verbose mode: $_verbose');
    if (attached) {
      report.writeln(
          'storage: ${_formatBytes(storageBytes)} of ${_formatBytes(_maxTotalBytes)} '
          '($currentFileName + $archiveFileName)');
    } else {
      report.writeln('storage: file storage unavailable; buffering in memory');
    }
    if (_writeFailures > 0) {
      report.writeln('write failures: $_writeFailures'
          '${_lastWriteError != null ? ' (last: $_lastWriteError)' : ''}');
    }
    report
      ..writeln()
      ..writeln('Redacted locally: bearer tokens, pairing codes, private '
          'keys, certificate contents, and private filesystem paths.')
      ..writeln('Logs stay on this device until you share this file.');
  }

  Future<void> _appendSection(
    StringBuffer report,
    File file,
    String title, {
    required int maxBytes,
  }) async {
    final lines = await _tailLines(file, maxBytes: maxBytes);
    if (lines.isEmpty) return;
    report
      ..writeln()
      ..writeln('== $title ==');
    for (final line in lines) {
      report.writeln(line);
    }
  }

  /// Appends the iOS high-frame-rate Photos-export diagnostics that the
  /// native side writes under `Documents/ShadowPlayDiagnostics` when a user
  /// saves a recording from a DEBUG build. Public so the behavior is
  /// testable on every platform; callers decide when it applies (the export
  /// path guards on `Platform.isIOS`).
  Future<void> appendHighFrameRateReports(
    StringBuffer report,
    String documentsDirectoryPath,
  ) async {
    final root = documentsDirectoryPath.replaceFirst(RegExp(r'[\\/]+$'), '');
    final hfr =
        Directory('$root${Platform.pathSeparator}ShadowPlayDiagnostics');
    List<File> reports;
    try {
      reports = (await hfr.list().toList())
          .whereType<File>()
          .where((file) => file.path.endsWith('.txt'))
          .toList();
    } catch (_) {
      return;
    }
    if (reports.isEmpty) return;
    reports.sort((a, b) {
      try {
        return b.statSync().modified.compareTo(a.statSync().modified);
      } catch (_) {
        return 0;
      }
    });
    report
      ..writeln()
      ..writeln('== High-frame-rate Photos export diagnostics (iOS) ==');
    for (final file in reports.take(5)) {
      try {
        final length = await file.length();
        final lines = await _tailLines(file, maxBytes: 32 * 1024);
        report
          ..writeln()
          ..writeln('-- ${fileNameOf(file.path)} (${_formatBytes(length)}) --');
        for (final line in lines) {
          report.writeln(line);
        }
      } catch (_) {}
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    final kilobytes = bytes / 1024;
    if (kilobytes < 1024) return '${kilobytes.toStringAsFixed(1)}KB';
    return '${(kilobytes / 1024).toStringAsFixed(1)}MB';
  }
}
