import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/ui/settings_page.dart';
import 'widget_test.dart' show NoNetwork;

class _CountingDownloads extends DownloadStore {
  _CountingDownloads(super.app);
  int scans = 0;
  @override
  Future<int> usedBytes() async {
    scans++;
    return 1024;
  }
}

void main() {
  testWidgets(
    'settings uses installed version and avoids rescanning on theme changes',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: '果果',
        packageName: 'test',
        version: '2.3.4',
        buildNumber: '99',
        buildSignature: '',
      );
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      final downloads = _CountingDownloads(store);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(store: store, downloads: downloads),
        ),
      );
      await tester.pumpAndSettle();
      await store.setTheme(ThemeMode.dark);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('果果 · 2.3.4 (99)'), 300);
      expect(find.text('果果 · 2.3.4 (99)'), findsOneWidget);
      expect(downloads.scans, 1);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );
}
