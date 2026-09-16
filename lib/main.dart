import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'data/app_store.dart';
import 'data/download_store.dart';
import 'data/storage.dart';
import 'platform/provider_client.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Bootstrap());
}

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});
  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  AppStore? _store;
  DownloadStore? _downloads;
  String? _error;
  StreamSubscription<List<ConnectivityResult>>? _network;
  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    setState(() => _error = null);
    try {
      // No player exists during bootstrap. Remove remux files left by a
      // terminated process before creating new playback sessions.
      try {
        final temporary = await getTemporaryDirectory();
        final playback = Directory('${temporary.path}/playback');
        if (await playback.exists()) await playback.delete(recursive: true);
      } on FileSystemException {
        // Cache cleanup must not prevent access to records or downloads.
      }
      final directory = await getApplicationSupportDirectory();
      final provider = NativeProviderClient();
      final store = AppStore(
        storage: FileStorage(Directory('${directory.path}/records')),
        provider: provider,
      );
      await store.load();
      await provider.initialize('${directory.path}/providers');
      final downloads = DownloadStore(store);
      try {
        await downloads.initialize();
      } catch (_) {
        downloads.error = '下载组件尚未就绪，请重新打开应用后重试';
      }
      final connectivity = Connectivity();
      store.setOffline(
        (await connectivity.checkConnectivity()).contains(
          ConnectivityResult.none,
        ),
      );
      _network = connectivity.onConnectivityChanged.listen(
        (values) => store.setOffline(values.contains(ConnectivityResult.none)),
      );
      if (!mounted) {
        downloads.dispose();
        store.dispose();
        return;
      }
      setState(() {
        _store = store;
        _downloads = downloads;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_store != null) {
      return GuoguoApp(store: _store!, downloads: _downloads!);
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: guoguoTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.play_circle_outline_rounded,
                  size: 64,
                  color: forest,
                ),
                const SizedBox(height: 20),
                const Text(
                  '果果',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _error == null ? '好故事，接着看' : '暂时无法打开，原有记录已保留',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (_error == null)
                  const CircularProgressIndicator()
                else ...[
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: _initialize, child: const Text('重试')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _network?.cancel();
    _downloads?.dispose();
    _store?.dispose();
    super.dispose();
  }
}

class GuoguoApp extends StatelessWidget {
  const GuoguoApp({
    super.key,
    required this.store,
    required this.downloads,
    this.autoLoad = true,
  });
  final AppStore store;
  final DownloadStore downloads;
  final bool autoLoad;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => MaterialApp(
      title: '果果',
      debugShowCheckedModeBanner: false,
      theme: guoguoTheme(Brightness.light),
      darkTheme: guoguoTheme(Brightness.dark),
      themeMode: store.themeMode,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: HomePage(store: store, downloads: downloads, autoLoad: autoLoad),
    ),
  );
}
