import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

import 'download_recovery_test.dart' show FakeDriver, PlanProvider;

const _refusal = ProviderException(
  'fixed registration failure',
  diagnostic: {
    'source': 'hongguo',
    'method': 'downloadPlan',
    'result': 'failed',
    'sourceStage': 'registration',
    'sourceFailure': 'registration_failed',
  },
);

class _Provider extends PlanProvider {
  bool refuseHongguo = false;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    if (refuseHongguo &&
        method == 'downloadPlan' &&
        (args['id'] as String).startsWith('hongguo:')) {
      throw _refusal;
    }
    return super.call(method, args);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'source refusal keeps typed evidence and submitted tasks; manual retry and other sources work',
    () async {
      final root = await Directory.systemTemp.createTemp('source-refusal-');
      final provider = _Provider();
      final app = AppStore(storage: MemoryStorage(), provider: provider);
      final driver = FakeDriver();
      final store = DownloadStore(
        app,
        driver: driver,
        storage: MemoryStorage(),
        root: root,
      );
      addTearDown(() async {
        store.dispose();
        app.dispose();
        await root.delete(recursive: true);
      });
      const drama = Drama(
        id: 'hongguo:1',
        source: DramaSource.hongguo,
        title: '同源下载',
      );
      final first = Episode.fromJson({'id': 'one'}, 0);
      await store.enqueue(drama, first, 0);
      final entry = store.entries.single;
      final retained = File('${entry.directory}/1.bin');
      await retained.writeAsString('keep partial bytes');
      provider.refuseHongguo = true;
      final refusal = throwsA(
        isA<ProviderException>().having(
          (e) => e.stopsSourceBatch,
          'typed refusal preserved',
          isTrue,
        ),
      );
      await expectLater(
        store.enqueue(drama, Episode.fromJson({'id': 'two'}, 1), 1),
        refusal,
      );
      expect(store.entries, [entry]);
      expect(driver.submitted, hasLength(2));
      expect(driver.canceled, isEmpty);
      await expectLater(store.retry(entry), refusal);
      expect(await retained.readAsString(), 'keep partial bytes');
      expect(driver.canceled, isEmpty);
      await store.enqueue(
        const Drama(
          id: 'huangju:1',
          source: DramaSource.huangju,
          title: '其他来源',
        ),
        first,
        0,
      );
      expect(store.entries, hasLength(2));
      provider.refuseHongguo = false;
      await store.retry(entry);
      expect(entry.failure, isNull);
      expect(await retained.readAsString(), 'keep partial bytes');
    },
  );
}
