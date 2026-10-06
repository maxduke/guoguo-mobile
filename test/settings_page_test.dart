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
  int bytes = 1024;
  @override
  Future<void> refreshUsage() async {
    scans++;
  }

  @override
  int? bytesFor(Iterable<DownloadEntry> entries) => bytes;
  void updateUsage(int value) {
    bytes = value;
    notifyListeners();
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
      await store.preferences.setTheme(ThemeMode.dark);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('果果 · 2.3.4 (99)'), 300);
      expect(find.text('果果 · 2.3.4 (99)'), findsOneWidget);
      expect(downloads.scans, 1);
      await tester.scrollUntilVisible(find.textContaining('1.0 KB'), -200);
      downloads.updateUsage(0);
      await tester.pumpAndSettle();
      expect(find.text('0 B · 在下载页按剧管理'), findsOneWidget);
      expect(downloads.scans, 1);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );
}
