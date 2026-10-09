import 'dart:io';

import 'package:path/path.dart' as path;

bool missingFileScope(FileSystemException error, String scope) =>
    error.osError?.errorCode == 2 &&
    error.path != null &&
    path.normalize(error.path!) == path.normalize(scope);

/// Logical sizes of files within this directory, without following links.
/// A missing directory is empty; an unreadable scope has unknown size.
Future<int?> directoryFileBytes(Directory directory) async {
  try {
    if (await FileSystemEntity.isLink(directory.path)) return null;
    var bytes = 0;
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is File) bytes += await entry.length();
    }
    return bytes;
  } on FileSystemException catch (error) {
    if (missingFileScope(error, directory.path)) return 0;
    return null;
  }
}

Future<int?> fileBytes(File file) async {
  try {
    if (await FileSystemEntity.isLink(file.path) ||
        await FileSystemEntity.isDirectory(file.path)) {
      return null;
    }
    return await file.length();
  } on FileSystemException catch (error) {
    return error.osError?.errorCode == 2 ? 0 : null;
  }
}
