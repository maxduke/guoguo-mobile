import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../domain/models.dart';
import 'app_store.dart';
import 'storage.dart';

class LibraryImportPreview {
  const LibraryImportPreview(
    this.items,
    this.skipped,
    this.rejected,
    this.duplicates,
  );
  final List<Drama> items;
  final int skipped, rejected, duplicates;
}

class LibraryExchange {
  const LibraryExchange(this.store);
  final AppStore store;
  static const maxBytes = 32 * 1024 * 1024;

  Future<LibraryImportPreview> inspect(File file) async {
    if (await file.length() > maxBytes) {
      throw const FormatException('剧库文件超过 32 MB');
    }
    final response = await store.provider.call('libraryImport', {
      'path': file.absolute.path,
    });
    // Parse the entire batch before changing persistent application state.
    final itemsPath = response['itemsPath'] as String?;
    List<Drama> items;
    if (itemsPath != null) {
      final normalized = File(itemsPath);
      try {
        if (await normalized.length() > maxBytes) {
          throw const FormatException('剧库内容超过 32 MB');
        }
        items = await _readLibraryItems(itemsPath);
      } finally {
        if (await normalized.exists()) await normalized.delete();
      }
    } else {
      items = (response['items'] as List)
          .map((row) => Drama.fromJson(Map<String, dynamic>.from(row as Map)))
          .toList();
    }
    if (items.length > 200000) throw const FormatException('剧库条目超过 20 万条');
    return LibraryImportPreview(
      items,
      response['skipped'] as int? ?? 0,
      response['rejected'] as int? ?? 0,
      response['duplicates'] as int? ?? 0,
    );
  }

  Future<Map<String, int>> merge(LibraryImportPreview preview) =>
      store.catalog.importLibraryRows(preview.items);

  Future<File> export(Directory directory, {bool compressed = true}) async {
    await directory.create(recursive: true);
    final rows = {
      for (final drama in store.catalog.catalogs.values.expand((rows) => rows))
        drama.key: drama,
    }.values.toList();
    if (rows.length > 200000) throw const FormatException('剧库条目超过 20 万条');
    final document = {
      'app': 'guoguo',
      'kind': 'library',
      'version': 1,
      'count': rows.length,
      'dramas': rows
          .map(
            (row) => {
              ...row.toJson(),
              'source': row.id.contains(':')
                  ? row.id.split(':').first
                  : 'cloudfront',
              'sourceId': row.id.contains(':')
                  ? row.id.substring(row.id.indexOf(':') + 1)
                  : row.id,
              'onlineDate': row.date,
              'releaseStatus': row.status,
            },
          )
          .toList(),
    };
    final text = await encodeJsonInBackground(document);
    if (utf8.encode(text).length > maxBytes) {
      throw const FormatException('剧库内容超过 32 MB');
    }
    final input = await File(
      '${directory.path}/.guoguo-library-${DateTime.now().microsecondsSinceEpoch}.json',
    ).create();
    try {
      await input.writeAsString(text, flush: true);
      final target = File(
        '${directory.path}/guoguo-library.${compressed ? 'xz' : 'json'}',
      );
      final response = await store.provider.call('libraryExport', {
        'path': input.absolute.path,
        'outputPath': target.absolute.path,
      });
      return File(response['path'] as String);
    } finally {
      if (await input.exists()) await input.delete();
    }
  }
}

Future<List<Drama>> _readLibraryItems(String path) => Isolate.run(() async {
  final rows = jsonDecode(await File(path).readAsString()) as List;
  return rows
      .map((row) => Drama.fromJson(Map<String, dynamic>.from(row as Map)))
      .toList();
});
