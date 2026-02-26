import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('StreamAudioCache');

class StreamAudioCacheStats {
  final int fileCount;
  final int totalSizeBytes;
  final int maxSizeBytes;

  const StreamAudioCacheStats({
    required this.fileCount,
    required this.totalSizeBytes,
    required this.maxSizeBytes,
  });
}

class _StreamAudioCacheEntry {
  final String filePath;
  final int sizeBytes;
  final int lastAccessEpochMs;

  const _StreamAudioCacheEntry({
    required this.filePath,
    required this.sizeBytes,
    required this.lastAccessEpochMs,
  });

  _StreamAudioCacheEntry copyWith({
    String? filePath,
    int? sizeBytes,
    int? lastAccessEpochMs,
  }) {
    return _StreamAudioCacheEntry(
      filePath: filePath ?? this.filePath,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      lastAccessEpochMs: lastAccessEpochMs ?? this.lastAccessEpochMs,
    );
  }

  Map<String, dynamic> toJson() => {
    'file_path': filePath,
    'size_bytes': sizeBytes,
    'last_access_ms': lastAccessEpochMs,
  };

  static _StreamAudioCacheEntry? fromJson(Map<String, dynamic> json) {
    final filePath = (json['file_path'] as String?)?.trim() ?? '';
    if (filePath.isEmpty) return null;

    final sizeBytes = (json['size_bytes'] as num?)?.toInt() ?? 0;
    final lastAccessEpochMs = (json['last_access_ms'] as num?)?.toInt() ?? 0;
    return _StreamAudioCacheEntry(
      filePath: filePath,
      sizeBytes: sizeBytes < 0 ? 0 : sizeBytes,
      lastAccessEpochMs: lastAccessEpochMs,
    );
  }
}

class StreamAudioCacheManager {
  static const String _cacheDirName = 'stream_audio_cache';
  static const String _indexKey = 'stream_audio_cache_index_v1';
  static const int _defaultMaxSizeBytes = 1024 * 1024 * 1024; // 1 GB
  static const int _maxPlayCountEntries = 3000;

  StreamAudioCacheManager._();
  static final StreamAudioCacheManager instance = StreamAudioCacheManager._();

  final Random _random = Random();
  final Set<String> _inFlightTrackKeys = <String>{};

  Future<void> _queue = Future<void>.value();

  Directory? _cacheDir;
  int _maxSizeBytes = _defaultMaxSizeBytes;
  bool _loaded = false;

  final Map<String, _StreamAudioCacheEntry> _entries =
      <String, _StreamAudioCacheEntry>{};
  final Map<String, int> _playCounts = <String, int>{};

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> initialize({required int maxSizeBytes}) {
    return _serialize(() async {
      await _ensureLoadedLocked();
      _maxSizeBytes = maxSizeBytes < 0 ? 0 : maxSizeBytes;
      await _enforceLimitLocked();
      await _persistLocked();
    });
  }

  Future<StreamAudioCacheStats> getStats({required int maxSizeBytes}) {
    return _serialize(() async {
      await _ensureLoadedLocked();
      _maxSizeBytes = maxSizeBytes < 0 ? 0 : maxSizeBytes;
      await _enforceLimitLocked();
      await _persistLocked();

      var total = 0;
      for (final entry in _entries.values) {
        total += entry.sizeBytes;
      }

      return StreamAudioCacheStats(
        fileCount: _entries.length,
        totalSizeBytes: total,
        maxSizeBytes: _maxSizeBytes,
      );
    });
  }

  Future<int> recordPlayback(String trackKey) {
    return _serialize(() async {
      final key = trackKey.trim();
      if (key.isEmpty) return 0;
      await _ensureLoadedLocked();

      final next = (_playCounts[key] ?? 0) + 1;
      _playCounts[key] = next.clamp(0, 9999);
      _prunePlayCountsLocked();
      await _persistLocked();
      return _playCounts[key] ?? 0;
    });
  }

  Future<String?> getCachedFilePath(String trackKey) {
    return _serialize(() async {
      final key = trackKey.trim();
      if (key.isEmpty) return null;

      await _ensureLoadedLocked();
      final entry = _entries[key];
      if (entry == null) return null;

      final file = File(entry.filePath);
      if (!await file.exists()) {
        _entries.remove(key);
        await _persistLocked();
        return null;
      }

      _entries[key] = entry.copyWith(
        lastAccessEpochMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _persistLocked();
      return entry.filePath;
    });
  }

  Future<void> cacheTrackFromUrlIfFrequent({
    required String trackKey,
    required String streamUrl,
    required int minPlayCount,
    required String extensionHint,
  }) async {
    final normalizedKey = trackKey.trim();
    final normalizedUrl = streamUrl.trim();
    if (normalizedKey.isEmpty || normalizedUrl.isEmpty) return;
    if (!normalizedUrl.startsWith('http://') &&
        !normalizedUrl.startsWith('https://')) {
      return;
    }

    final shouldDownload = await _serialize(() async {
      await _ensureLoadedLocked();
      if (_maxSizeBytes <= 0) return false;
      if ((_playCounts[normalizedKey] ?? 0) < minPlayCount) return false;
      if (_entries.containsKey(normalizedKey)) return false;
      if (_inFlightTrackKeys.contains(normalizedKey)) return false;
      _inFlightTrackKeys.add(normalizedKey);
      return true;
    });

    if (!shouldDownload) return;

    File? downloaded;
    int downloadedSize = 0;
    try {
      final temp = await _downloadToTempFile(
        normalizedUrl,
        _sanitizeExtension(extensionHint),
      );
      if (temp == null) return;
      downloaded = temp.$1;
      downloadedSize = temp.$2;
    } catch (e) {
      _log.d('Stream cache download skipped for $normalizedKey: $e');
    }

    if (downloaded == null || downloadedSize <= 0) {
      try {
        await downloaded?.delete();
      } catch (_) {}
      await _serialize(() async {
        _inFlightTrackKeys.remove(normalizedKey);
      });
      return;
    }

    await _serialize(() async {
      try {
        await _ensureLoadedLocked();
        if (_maxSizeBytes <= 0) {
          try {
            await downloaded!.delete();
          } catch (_) {}
          return;
        }

        final existing = _entries[normalizedKey];
        if (existing != null) {
          try {
            await downloaded!.delete();
          } catch (_) {}
          return;
        }

        final ext = p.extension(downloaded!.path);
        final finalName =
            'cache_${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(1 << 30)}$ext';
        final finalPath = p.join(_cacheDir!.path, finalName);

        try {
          await downloaded.rename(finalPath);
        } catch (_) {
          try {
            await downloaded.copy(finalPath);
            await downloaded.delete();
          } catch (e) {
            _log.w('Failed to finalize stream cache file: $e');
            try {
              await downloaded.delete();
            } catch (_) {}
            return;
          }
        }

        _entries[normalizedKey] = _StreamAudioCacheEntry(
          filePath: finalPath,
          sizeBytes: downloadedSize,
          lastAccessEpochMs: DateTime.now().millisecondsSinceEpoch,
        );
        await _enforceLimitLocked();
        await _persistLocked();
        _log.d('Cached stream audio for $normalizedKey at $finalPath');
      } finally {
        _inFlightTrackKeys.remove(normalizedKey);
      }
    });
  }

  Future<void> clearCache() {
    return _serialize(() async {
      await _ensureLoadedLocked();

      for (final entry in _entries.values) {
        try {
          await File(entry.filePath).delete();
        } catch (_) {}
      }
      _entries.clear();

      if (_cacheDir != null && await _cacheDir!.exists()) {
        try {
          await _cacheDir!.delete(recursive: true);
        } catch (_) {}
        await _cacheDir!.create(recursive: true);
      }

      await _persistLocked();
    });
  }

  Future<void> _ensureLoadedLocked() async {
    if (_loaded) return;
    final appSupport = await getApplicationSupportDirectory();
    _cacheDir = Directory(p.join(appSupport.path, _cacheDirName));
    await _cacheDir!.create(recursive: true);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_indexKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final json = Map<String, dynamic>.from(decoded);

          final loadedMaxSize = (json['max_size_bytes'] as num?)?.toInt();
          if (loadedMaxSize != null && loadedMaxSize >= 0) {
            _maxSizeBytes = loadedMaxSize;
          }

          final entriesRaw = json['entries'];
          if (entriesRaw is Map) {
            for (final rawEntry in entriesRaw.entries) {
              final key = rawEntry.key.toString().trim();
              if (key.isEmpty || rawEntry.value is! Map) continue;
              final parsed = _StreamAudioCacheEntry.fromJson(
                Map<String, dynamic>.from(rawEntry.value as Map),
              );
              if (parsed != null) {
                _entries[key] = parsed;
              }
            }
          }

          final playCountsRaw = json['play_counts'];
          if (playCountsRaw is Map) {
            for (final rawEntry in playCountsRaw.entries) {
              final key = rawEntry.key.toString().trim();
              if (key.isEmpty) continue;
              final value = (rawEntry.value as num?)?.toInt() ?? 0;
              if (value > 0) {
                _playCounts[key] = value.clamp(0, 9999);
              }
            }
          }
        }
      } catch (e) {
        _log.w('Failed to parse stream audio cache index: $e');
      }
    }

    await _reconcileFilesLocked();
    await _enforceLimitLocked();
    await _persistLocked();
    _loaded = true;
  }

  Future<void> _reconcileFilesLocked() async {
    final toRemove = <String>[];
    for (final entry in _entries.entries) {
      final file = File(entry.value.filePath);
      if (!await file.exists()) {
        toRemove.add(entry.key);
        continue;
      }

      try {
        final length = await file.length();
        _entries[entry.key] = entry.value.copyWith(
          sizeBytes: length < 0 ? 0 : length,
        );
      } catch (_) {
        toRemove.add(entry.key);
      }
    }
    for (final key in toRemove) {
      _entries.remove(key);
    }
  }

  Future<void> _enforceLimitLocked() async {
    if (_maxSizeBytes <= 0) {
      for (final entry in _entries.values) {
        try {
          await File(entry.filePath).delete();
        } catch (_) {}
      }
      _entries.clear();
      return;
    }

    var total = 0;
    for (final entry in _entries.values) {
      total += entry.sizeBytes;
    }

    if (total <= _maxSizeBytes) {
      return;
    }

    final sortedKeys = _entries.entries.toList(growable: false)
      ..sort(
        (a, b) =>
            a.value.lastAccessEpochMs.compareTo(b.value.lastAccessEpochMs),
      );

    for (final entry in sortedKeys) {
      try {
        await File(entry.value.filePath).delete();
      } catch (_) {}
      _entries.remove(entry.key);
      total -= entry.value.sizeBytes;
      if (total <= _maxSizeBytes) break;
    }
  }

  void _prunePlayCountsLocked() {
    if (_playCounts.length <= _maxPlayCountEntries) return;
    final excess = _playCounts.length - _maxPlayCountEntries;
    final keys = _playCounts.keys.take(excess).toList(growable: false);
    for (final key in keys) {
      _playCounts.remove(key);
    }
  }

  Future<void> _persistLocked() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'max_size_bytes': _maxSizeBytes,
      'entries': {
        for (final entry in _entries.entries) entry.key: entry.value.toJson(),
      },
      'play_counts': _playCounts,
    };
    await prefs.setString(_indexKey, jsonEncode(payload));
  }

  String _sanitizeExtension(String extensionHint) {
    final normalized = extensionHint.trim().toLowerCase();
    if (normalized == 'flac' || normalized == '.flac') return '.flac';
    if (normalized == 'm4a' || normalized == '.m4a') return '.m4a';
    if (normalized == 'mp3' || normalized == '.mp3') return '.mp3';
    if (normalized == 'opus' || normalized == '.opus') return '.opus';
    if (normalized == 'ogg' || normalized == '.ogg') return '.ogg';
    return '.cache';
  }

  Future<(File, int)?> _downloadToTempFile(String streamUrl, String ext) async {
    final targetDir = _cacheDir;
    if (targetDir == null) return null;

    final tempName =
        'tmp_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 30)}$ext';
    final tempFile = File(p.join(targetDir.path, tempName));
    final sink = tempFile.openWrite();
    var totalBytes = 0;
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);

    try {
      final request = await client.getUrl(Uri.parse(streamUrl));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'HTTP ${response.statusCode} while caching stream',
          uri: Uri.parse(streamUrl),
        );
      }

      await for (final chunk in response) {
        totalBytes += chunk.length;
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await tempFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }

    if (totalBytes <= 0) {
      try {
        await tempFile.delete();
      } catch (_) {}
      return null;
    }

    return (tempFile, totalBytes);
  }
}
