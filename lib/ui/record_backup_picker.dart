import 'package:file_picker/file_picker.dart';

import '../data/record_backup_codec.dart';
import '../domain/models.dart';
import '../domain/user_input_exception.dart';

Future<RecordBackup?> pickRecordBackup({bool Function()? isActive}) async {
  final selected = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['json'],
  );
  if (selected == null || isActive?.call() == false) return null;
  final length = await selected.length();
  if (length == null || length > maxRecordBackupBytes) {
    throw const UserInputException('备份文件超过 20 MB 或无法读取大小');
  }
  if (isActive?.call() == false) return null;
  final bytes = await selected.readAsBytes();
  if (isActive?.call() == false) return null;
  return decodeRecordBackupBytes(bytes);
}
