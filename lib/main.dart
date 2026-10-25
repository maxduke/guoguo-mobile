import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';

import 'data/app_store.dart';
import 'data/app_startup.dart';
import 'data/download_store.dart';
import 'data/storage.dart';
import 'data/startup_record_recovery.dart';
import 'platform/provider_client.dart';
import 'platform/playback_temporary_files.dart';
import 'platform/network_policy.dart';
import 'platform/device_profile.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';
import 'ui/record_recovery_page.dart';
import 'ui/television_scope.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Bootstrap());
}

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key, this.load});
  final Future<AppStartup> Function()? load;
  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  AppStartup? _startup;
  String? _error;
  StartupRecordRecovery? _recordRecovery;
  bool _loading = false;
  bool _recoveringRecords = false;
  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (_loading || !mounted) return;
    _loading = true;
    setState(() => _error = null);
    _recordRecovery = null;
    try {
      final startup = await (widget.load ?? _loadStartup)();
      if (!mounted) {
        startup.dispose();
        return;
      }
      startup.start();
      setState(() => _startup = startup);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '本地记录暂时无法读取，请检查设备空间后重试';
          _recordRecovery = error is RecordLoadFailure ? error.recovery : null;
        });
      }
    } finally {
      _loading = false;
    }
  }

  Future<void> _recoverRecords(BuildContext context) async {
    final recovery = _recordRecovery;
    if (recovery == null || _loading || _recoveringRecords) return;
    _recoveringRecords = true;
    try {
      final recovered = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => RecordRecoveryPage(recovery: recovery),
        ),
      );
      if (recovered == true && mounted) await _initialize();
    } finally {
      _recoveringRecords = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_startup != null) {
      return GuoguoApp(
        store: _startup!.store,
        downloads: _startup!.downloads,
        startup: _startup,
        autoLoad: false,
      );
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: guoguoTheme(Brightness.light),
      darkTheme: guoguoTheme(Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - 56).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
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
                        FilledButton(
                          onPressed: _initialize,
                          child: const Text('重试'),
                        ),
                        if (_recordRecovery != null)
                          TextButton(
                            onPressed: () =>
                                unawaited(_recoverRecords(context)),
                            child: const Text('记录恢复'),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _startup?.dispose();
    super.dispose();
  }
}

Future<AppStartup> _loadStartup() async {
  // Keep cleanup before any player can acquire a file in this directory.
  try {
    final temporary = await getTemporaryDirectory();
    await PlaybackTemporaryFiles.clearUnused(
      Directory('${temporary.path}/playback'),
    );
  } catch (_) {
    // Reconstructible cache cleanup cannot block access to durable records.
  }
  final directory = await getApplicationSupportDirectory();
  final provider = NativeProviderClient.shared;
  final storage = AppFileStorage(Directory('${directory.path}/records'));
  final store = AppStore(storage: storage, provider: provider);
  try {
    await store.load();
  } catch (_) {
    store.dispose();
    throw RecordLoadFailure(StartupRecordRecovery(storage));
  }
  final downloads = DownloadStore(store, waitForProvider: () => provider.ready);
  final connectivity = Connectivity();
  return AppStartup(
    television: await isAndroidTelevision(),
    store: store,
    downloads: downloads,
    initializeCore: () => provider.initialize('${directory.path}/providers'),
    checkOffline: () async =>
        isOfflineNetwork(await connectivity.checkConnectivity()),
    offlineChanges: connectivity.onConnectivityChanged.map(isOfflineNetwork),
    checkWifi: () async =>
        isWifiNetwork(await connectivity.checkConnectivity()),
    wifiChanges: connectivity.onConnectivityChanged.map(isWifiNetwork),
  );
}

class GuoguoApp extends StatelessWidget {
  const GuoguoApp({
    super.key,
    required this.store,
    required this.downloads,
    this.autoLoad = true,
    this.startup,
    this.television,
  });
  final AppStore store;
  final DownloadStore downloads;
  final bool autoLoad;
  final AppStartup? startup;
  final bool? television;
  bool get _television => television ?? startup?.television ?? false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store.preferences.theme,
    child: HomePage(
      store: store,
      downloads: downloads,
      autoLoad: autoLoad,
      startup: startup,
    ),
    builder: (context, child) => MaterialApp(
      title: '果果',
      debugShowCheckedModeBanner: false,
      theme: guoguoTheme(Brightness.light, television: _television),
      darkTheme: guoguoTheme(Brightness.dark, television: _television),
      themeMode: store.preferences.themeMode,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, page) => TelevisionScope(
        enabled: _television,
        child: Shortcuts(
          shortcuts: _television
              ? const {
                  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.gameButtonA):
                      ActivateIntent(),
                }
              : const {},
          child: FocusTraversalGroup(child: page!),
        ),
      ),
      home: child,
    ),
  );
}
