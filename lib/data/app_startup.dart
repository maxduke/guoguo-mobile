import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/provider_client.dart';
import 'app_store.dart';
import 'download_store.dart';

/// Owns startup work after durable local data is available to the UI.
class AppStartup extends ChangeNotifier {
  AppStartup({
    required this.store,
    required this.downloads,
    required Future<void> Function() initializeCore,
    required Future<bool> Function() checkOffline,
    required Stream<bool> offlineChanges,
  }) : _initializeCore = initializeCore,
       _checkOffline = checkOffline,
       _offlineChanges = offlineChanges;

  final AppStore store;
  final DownloadStore downloads;
  final Future<void> Function() _initializeCore;
  final Future<bool> Function() _checkOffline;
  final Stream<bool> _offlineChanges;
  StreamSubscription<bool>? _network;
  Future<void>? _coreTask, _networkTask;
  bool _started = false, _disposed = false;
  int _networkRevision = 0;
  bool coreReady = false;
  String? coreError, networkError;
  bool get coreLoading => _coreTask != null;
  bool get networkLoading => _networkTask != null;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(retryCore());
    unawaited(downloads.initialize());
    unawaited(retryNetwork());
  }

  Future<void> retryCore() {
    if (_disposed || coreReady) return Future.value();
    if (_coreTask != null) return _coreTask!;
    coreError = null;
    _coreTask = Future<void>.microtask(_loadCore);
    notifyListeners();
    return _coreTask!;
  }

  Future<void> _loadCore() async {
    try {
      if (_disposed) return;
      await _initializeCore();
      if (_disposed) return;
      coreReady = true;
      // A core retry also releases download restoration and initial discovery.
      unawaited(downloads.initialize());
      unawaited(
        store.catalog.library.isEmpty
            ? store.catalog.refresh()
            : store.catalog.loadCategories(),
      );
    } catch (error) {
      if (!_disposed) {
        coreError = error is ProviderException
            ? error.message
            : '站源连接暂未就绪，可浏览已有记录，请重试';
      }
    } finally {
      _coreTask = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> retryNetwork() {
    if (_disposed) return Future.value();
    if (_networkTask != null) return _networkTask!;
    networkError = null;
    _networkTask = Future<void>.microtask(_loadNetwork);
    notifyListeners();
    return _networkTask!;
  }

  void _networkFailed() {
    if (_disposed) return;
    _networkRevision++;
    unawaited(_network?.cancel());
    _network = null;
    networkError = '网络状态暂时无法获取，可继续浏览，请重试';
    notifyListeners();
  }

  Future<void> _loadNetwork() async {
    var revision = _networkRevision;
    try {
      if (_disposed) return;
      _network ??= _offlineChanges.listen(
        (offline) {
          if (_disposed) return;
          _networkRevision++;
          store.setOffline(offline);
          networkError = null;
          notifyListeners();
        },
        onError: (Object _) => _networkFailed(),
        onDone: _networkFailed,
      );
      revision = _networkRevision;
      final offline = await _checkOffline();
      if (!_disposed && revision == _networkRevision) {
        store.setOffline(offline);
      }
    } catch (_) {
      if (!_disposed && revision == _networkRevision) {
        networkError = '网络状态暂时无法获取，可继续浏览，请重试';
      }
    } finally {
      _networkTask = null;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_network?.cancel());
    downloads.dispose();
    store.dispose();
    super.dispose();
  }
}
