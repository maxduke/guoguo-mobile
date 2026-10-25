import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/record_backup_codec.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/user_input_exception.dart';
import 'widget_test.dart' show NoNetwork;

void main() {
  test(
    'accepted near-limit backup remains importable after app export',
    () async {
      final incoming = RecordBackup(
        List.generate(
          30000,
          (i) => Drama(
            id: '$i',
            source: DramaSource.hongguo,
            title: 'story $i',
            description: 'x' * 500,
          ),
        ),
        [],
      );
      final app = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      addTearDown(app.dispose);
      app.records.restore(incoming, {});
      final bytes = await app.records.exportBackupBytes();
      expect(bytes.length, lessThanOrEqualTo(maxRecordBackupBytes));
      final restored = await decodeRecordBackupBytes(bytes);
      expect(restored.favorites.length, 30000);
      expect(restored.favorites.last.description, 'x' * 500);
    },
  );

  test(
    'UTF-8 export overflow rejects without modifying current records',
    () async {
      final drama = Drama(
        id: 'large',
        source: DramaSource.hongguo,
        title: '大记录',
        description: '界' * (maxRecordBackupBytes ~/ 3 + 1),
      );
      final app = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      addTearDown(app.dispose);
      app.records.restore(RecordBackup([drama], []), {});
      await expectLater(
        app.records.exportBackupBytes(),
        throwsA(isA<UserInputException>()),
      );
      expect(app.records.favorites[drama.key], same(drama));
    },
  );

  test(
    'import detaches mutable metadata and reserves its transaction',
    () async {
      final tags = ['original'];
      final rows = [
        Drama(id: 'one', source: DramaSource.hongguo, title: '作品', tags: tags),
      ];
      final app = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      addTearDown(app.dispose);
      final importing = app.records.importBackup(RecordBackup(rows, []));
      rows.clear();
      tags.add('later');
      await importing;
      expect(app.records.favorites.values.single.tags, ['original']);
      final raw = app.records.exportBackup();
      expect(jsonDecode(raw)['version'], 2);
    },
  );
}
