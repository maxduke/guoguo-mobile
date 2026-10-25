import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'download_entry.dart';
import 'storage.dart';

Set<String> protectedDownloadDirectories(Map<String, dynamic> state) {
  final raw = state['protectedDirectories'] as List? ?? [];
  if (raw.length > 100000 ||
      raw.any((id) => id is! String || !RegExp(r'^\d{1,255}$').hasMatch(id))) {
    throw const FormatException('保留下载目录格式不正确');
  }
  return raw.cast<String>().toSet();
}

class DownloadRecoveryPreview {
  DownloadRecoveryPreview(
    List<DownloadEntry> entries,
    this.rejected,
    Set<String> directories,
  ) : entries = List.unmodifiable(entries),
      protectedDirectories = Set.unmodifiable(directories);
  final List<DownloadEntry> entries;
  final int rejected;
  final Set<String> protectedDirectories;
}

class DownloadManifestRecovery {
  DownloadManifestRecovery(this.storage, this.root);
  final FileStorage storage;
  final Directory root;

  Future<DownloadRecoveryPreview> inspect() async {
    Map<String, dynamic>? state;
    try {
      state = await storage.read();
    } catch (_) {
      // Replacement still requires preserving the exact original successfully.
    }
    final raw = state?['jobs'];
    var rejected = raw is List ? 0 : 1;
    final candidates = <DownloadEntry>[];
    for (final row in raw is List ? raw : const []) {
      try {
        final entry = DownloadEntry.fromJson(
          Map<String, dynamic>.from(row as Map),
        );
        bool safeName(String name) =>
            name.isNotEmpty &&
            name != '.' &&
            name != '..' &&
            !name.contains(RegExp(r'[/\\\x00]'));
        if (!RegExp(r'^\d{1,32}$').hasMatch(entry.id) ||
            !safeName(entry.input) ||
            entry.index < 0 ||
            entry.tasks.any(
              (t) =>
                  !safeName(t.filename) ||
                  t.group != 'guoguo' ||
                  t.metaData != entry.id ||
                  t.directory != 'guoguo/${entry.id}' ||
                  t.baseDirectory != BaseDirectory.applicationDocuments ||
                  !t.taskId.startsWith('${entry.id}_'),
            )) {
          throw const FormatException('下载条目不完整');
        }
        candidates.add(entry);
      } catch (_) {
        rejected++;
      }
    }
    final counts = <String, int>{};
    for (final entry in candidates) {
      counts.update(entry.id, (n) => n + 1, ifAbsent: () => 1);
    }
    final entries = candidates.where((entry) => counts[entry.id] == 1).toList();
    rejected += candidates.length - entries.length;
    final known = entries.map((entry) => entry.id).toSet();
    final retained = <String>{};
    if (await root.exists()) {
      await for (final item in root.list(followLinks: false)) {
        final name = item.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (item is Directory &&
            RegExp(r'^\d{1,255}$').hasMatch(name) &&
            !known.contains(name)) {
          retained.add(name);
        }
      }
    }
    return DownloadRecoveryPreview(entries, rejected, retained);
  }

  Future<File> preserve() => storage.preserve();

  Future<File> restore(DownloadRecoveryPreview preview) =>
      storage.replacePreserving({
        'version': 1,
        'jobs': preview.entries.map((entry) => entry.toJson()).toList(),
        'preserveUnknownDirectories': true,
        if (preview.protectedDirectories.isNotEmpty)
          'protectedDirectories': preview.protectedDirectories.toList(),
      });
}
