import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';
import '../platform/media_preparer.dart';
import '../platform/file_usage.dart';
import '../platform/provider_client.dart';
import 'app_store.dart';
import 'storage.dart';
import 'download_driver.dart';

String downloadFailure(TaskRecord record) => switch (record.exception) {
  TaskFileSystemException() => '视频文件写入失败，请检查设备剩余空间后重试',
  TaskConnectionException() => '网络连接中断或超时，请检查网络后重试',
  TaskResumeException() => '断点已失效，请重试；已完成分片会保留',
  TaskHttpException(:final httpResponseCode) =>
    '资源请求失败（HTTP $httpResponseCode），请重试更新资源',
  TaskUrlException() => '资源地址无效，请重试更新资源',
  _ => record.status == TaskStatus.notFound ? '资源已失效，请重试更新资源' : '资源下载失败，请重试',
};

enum DownloadPhase {
  queued('排队中'),
  downloading('下载中'),
  paused('已暂停'),
  retrying('等待自动重试'),
  failed('下载失败'),
  waitingProcessing('等待整理'),
  processing('正在整理视频'),
  complete('已完成');

  const DownloadPhase(this.label);
  final String label;
}

String formatDownloadBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class DownloadEntry {
  DownloadEntry({
    required this.id,
    required this.drama,
    required this.episode,
    required this.index,
    required this.directory,
    required this.input,
    required this.contentKey,
    required this.process,
    required this.tasks,
    this.ready = false,
    this.userPaused = false,
    this.failure,
    this.refreshOnResume = false,
    Map<String, String>? assetIdentities,
  }) : assetIdentities = assetIdentities ?? {};
  final String id, directory, input, contentKey;
  final Drama drama;
  final Episode episode;
  final int index;
  final bool process;
  final List<DownloadTask> tasks;
  final Map<String, String> assetIdentities;
  bool refreshOnResume;
  bool ready, userPaused, processing = false;
  TaskStatus status = TaskStatus.enqueued;
  double progress = 0;
  int downloadedBytes = 0;
  int? totalBytes;
  bool awaitingProcessing = false;
  String? failure;
  bool get complete => ready;
  String get output => '$directory/${process ? 'video.mp4' : input}';
  DownloadPhase get phase {
    if (ready) return DownloadPhase.complete;
    if (processing) return DownloadPhase.processing;
    if (failure != null) return DownloadPhase.failed;
    if (userPaused) return DownloadPhase.paused;
    if (awaitingProcessing) return DownloadPhase.waitingProcessing;
    return switch (status) {
      TaskStatus.running => DownloadPhase.downloading,
      TaskStatus.paused => DownloadPhase.paused,
      TaskStatus.waitingToRetry => DownloadPhase.retrying,
      TaskStatus.failed ||
      TaskStatus.canceled ||
      TaskStatus.notFound => DownloadPhase.failed,
      _ => DownloadPhase.queued,
    };
  }

  String get label => failure ?? phase.label;
  bool get canPause =>
      !processing &&
      !ready &&
      {
        DownloadPhase.queued,
        DownloadPhase.downloading,
        DownloadPhase.retrying,
        DownloadPhase.waitingProcessing,
      }.contains(phase);
  bool get canResume => phase == DownloadPhase.paused;
  bool get canRetry => phase == DownloadPhase.failed;
  Map<String, dynamic> toJson() => {
    'id': id,
    'drama': drama.toJson(),
    'episode': episode.raw,
    'index': index,
    'directory': directory,
    'input': input,
    'contentKey': contentKey,
    'process': process,
    'assetIdentities': assetIdentities,
    'refreshOnResume': refreshOnResume,
    'tasks': tasks.map((t) => t.toJson()).toList(),
    'ready': ready,
    'userPaused': userPaused,
    'failure': failure,
  };
  factory DownloadEntry.fromJson(Map<String, dynamic> json) => DownloadEntry(
    id: json['id'] as String,
    drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
    episode: Episode.fromJson(
      Map<String, dynamic>.from(json['episode'] as Map),
      json['index'] as int,
    ),
    index: json['index'] as int,
    directory: json['directory'] as String,
    input: json['input'] as String,
    contentKey: json['contentKey'] as String,
    process: json['process'] == true,
    assetIdentities: Map<String, String>.from(
      json['assetIdentities'] as Map? ?? {},
    ),
    refreshOnResume: json['refreshOnResume'] == true,
    tasks: (json['tasks'] as List)
        .map((t) => DownloadTask.fromJson(Map<String, dynamic>.from(t as Map)))
        .toList(),
    ready: json['ready'] == true,
    userPaused: json['userPaused'] == true,
    failure: json['failure'] as String?,
  );
}

class DownloadStore extends ChangeNotifier with WidgetsBindingObserver {
  DownloadStore(
    this.app, {
    DownloadDriver? driver,
    LocalStorage? storage,
    Directory? root,
    Future<void> Function()? waitForProvider,
  }) : driver = driver ?? DownloadDriver(),
       _storage = storage,
       _root = root,
       _waitForProvider = waitForProvider;
  final DownloadDriver driver;
  final AppStore app;
  FileDownloader get downloader => driver.downloader;
  List<DownloadEntry> entries = [];
  StreamSubscription<TaskUpdate>? _subscription;
  LocalStorage? _storage;
  Directory? _root;
  final Future<void> Function()? _waitForProvider;
  Future<void>? _initialization, _manifestLoad;
  bool initialized = false, manifestLoaded = false;
  bool get initializing => _initialization != null;
  String? initializationError;
  String? _error, _manifestError;
  String? get error => _manifestError ?? initializationError ?? _error;
  set error(String? value) => _error = value;
  Timer? _refreshTimer;
  bool _verifyFiles = false;
  final Set<String> _removing = {};
  bool _loading = false,
      _reloadAgain = false,
      _disposed = false,
      _foreground = true,
      _finalizing = false;
  MediaPreparer? _processor;
  final Set<String> _enqueuing = {};
  final Map<String, int> bytesByEntry = {};
  Future<void>? _usageRefresh;
  bool _usageAgain = false;
  bool get measuringUsage => _usageRefresh != null;
  String? usageError;
  static const group = 'guoguo';

  Future<void> initialize() {
    if (_disposed) return Future.value();
    if (_initialization != null) return _initialization!;
    if (initialized) return Future.value();
    initializationError = null;
    if (!manifestLoaded) _manifestLoad = Future<void>.microtask(_loadManifest);
    _initialization = Future<void>.microtask(_initialize);
    notifyListeners();
    return _initialization!;
  }

  Future<void> _loadManifest() async {
    if (manifestLoaded || _disposed) return;
    _root ??= Directory(
      '${(await getApplicationDocumentsDirectory()).path}/guoguo',
    );
    if (_disposed) return;
    await _root!.create(recursive: true);
    if (_disposed) return;
    _storage ??= FileStorage(
      Directory('${(await getApplicationSupportDirectory()).path}/downloads'),
    );
    if (_disposed) return;
    final state = await _storage!.read();
    if (_disposed) return;
    if (state != null) {
      final loaded = (state['jobs'] as List)
          .map(
            (v) => DownloadEntry.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
      // Application container paths can change after an iOS update/reinstall.
      entries = loaded.map((entry) {
        final json = entry.toJson();
        json['directory'] = '${_root!.path}/${entry.id}';
        return DownloadEntry.fromJson(json);
      }).toList();
    }
    manifestLoaded = true;
    notifyListeners();
  }

  Future<void> _initialize() async {
    try {
      await _manifestLoad;
      if (_disposed) return;
      await _waitForProvider?.call();
      if (_disposed) return;
      await driver.trackTasks();
      if (_disposed) return;
      if (!await driver.requireWiFi(app.preferences.cellularDownloads)) {
        throw const ProviderException('下载网络规则未能更新，请重试');
      }
      if (_disposed) return;
      await driver.start();
      if (_disposed) return;
      downloader.configureNotificationForGroup(
        group,
        running: const TaskNotification('正在下载 {displayName}', '{progress}'),
        error: const TaskNotification('下载未完成', '{displayName}'),
        paused: const TaskNotification('下载已暂停', '{displayName}'),
        progressBar: true,
      );
      WidgetsBinding.instance.addObserver(this);
      _foreground =
          WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      _subscription = driver.updates.listen((_) {
        if (_disposed) return;
        _refreshTimer ??= Timer(const Duration(milliseconds: 300), () {
          _refreshTimer = null;
          unawaited(reload(verifyFiles: false));
        });
      });
      await cleanupOrphans();
      if (_disposed) return;
      await restorePendingTasks();
      if (_disposed) return;
      initialized = true;
      await reload();
    } catch (_) {
      if (!_disposed) {
        initializationError = '下载组件暂未就绪，请重试；已保存文件会保留';
        await _subscription?.cancel();
        _subscription = null;
        _refreshTimer?.cancel();
        _refreshTimer = null;
        WidgetsBinding.instance.removeObserver(this);
      }
    } finally {
      _initialization = null;
      if (!_disposed) notifyListeners();
    }
  }

  void _requireReady() {
    if (_disposed ||
        initializing ||
        initializationError != null ||
        _root == null) {
      throw const ProviderException('下载组件尚未就绪，请稍候或在下载页重试');
    }
  }

  Future<void> restorePendingTasks() async {
    for (final entry
        in entries
            .where((e) => !e.ready && !e.userPaused && e.failure == null)
            .toList()) {
      if (_disposed) return;
      try {
        final missing = <DownloadTask>[];
        for (final task in entry.tasks) {
          if (await driver.record(task.taskId) == null) missing.add(task);
          if (_disposed) return;
        }
        if (missing.isEmpty) continue;
        if (entry.refreshOnResume) {
          await _retry(entry);
        } else {
          for (final task in missing) {
            if (_disposed) return;
            if (!await driver.enqueue(task)) {
              throw const ProviderException('下载恢复未能入队，请重试；已下载文件已保留');
            }
          }
        }
      } catch (problem) {
        if (_disposed) return;
        entry.failure ??= problem is ProviderException
            ? problem.message
            : '下载恢复失败，请重试；已下载文件已保留';
        entry.status = TaskStatus.failed;
        try {
          await _save();
        } catch (_) {
          // Keep the manifest error visible while recovering the other entries.
        }
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _save() async {
    final target = _storage;
    if (target == null) return;
    try {
      await target.write({
        'version': 1,
        'jobs': entries.map((e) => e.toJson()).toList(),
      });
      _setManifestError(null);
    } catch (_) {
      _setManifestError('下载记录保存失败，请检查设备空间后下拉刷新重试');
      rethrow;
    }
  }

  void _setManifestError(String? value) {
    if (_manifestError == value) return;
    _manifestError = value;
    if (!_disposed) notifyListeners();
  }

  Future<void> setCellular(bool enabled) async {
    _requireReady();
    final ok = await driver.requireWiFi(enabled);
    if (!ok) throw const ProviderException('网络规则未能更新，请重试');
    await app.preferences.setNetwork(downloads: enabled);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(reload());
    } else {
      unawaited(_processor?.cancel());
    }
  }

  Future<void> reload({bool verifyFiles = true}) async {
    _verifyFiles = _verifyFiles || verifyFiles;
    if (_disposed ||
        _storage == null ||
        (!initialized && (initializing || initializationError != null))) {
      return;
    }
    if (_loading) {
      _reloadAgain = true;
      return;
    }
    _loading = true;
    final previousFailures = {for (final e in entries) e.id: e.failure};
    var checkedFiles = false;
    try {
      do {
        _reloadAgain = false;
        final checkFiles = _verifyFiles;
        _verifyFiles = false;
        checkedFiles = checkedFiles || checkFiles;
        final records = {for (final r in await driver.records()) r.taskId: r};
        if (_disposed) return;
        for (final entry in entries.toList()) {
          if (_removing.contains(entry.id)) continue;
          if (entry.ready) {
            if (!checkFiles || await File(entry.output).exists()) {
              entry.status = TaskStatus.complete;
              entry.progress = 1;
              continue;
            }
            entry.ready = false;
            entry.failure = '视频文件已不存在，请重新下载';
            entry.status = TaskStatus.failed;
            continue;
          }
          final parts = entry.tasks.map((t) => records[t.taskId]).toList();
          double partProgress(TaskRecord? part) =>
              part?.status == TaskStatus.complete
              ? 1
              : (part?.progress ?? 0).clamp(0, 1);
          entry.totalBytes =
              parts.isNotEmpty &&
                  parts.every((p) => p != null && p.expectedFileSize > 0)
              ? parts.fold<int>(0, (total, p) => total + p!.expectedFileSize)
              : null;
          entry.downloadedBytes = parts.fold<int>(
            0,
            (total, p) =>
                total +
                (p != null && p.expectedFileSize > 0
                    ? (p.expectedFileSize * partProgress(p)).round()
                    : 0),
          );
          entry.progress = parts.isEmpty
              ? 0
              : parts.fold<double>(0, (total, p) => total + partProgress(p)) /
                    parts.length;
          if (entry.totalBytes != null) {
            entry.progress = entry.downloadedBytes / entry.totalBytes!;
          }
          entry.awaitingProcessing =
              parts.isNotEmpty &&
              parts.every((p) => p?.status == TaskStatus.complete);
          if (entry.failure != null) {
            entry.status = TaskStatus.failed;
            continue;
          }
          if (entry.userPaused) {
            entry.status = TaskStatus.paused;
          } else if (parts.any(
            (p) =>
                p?.status == TaskStatus.failed ||
                p?.status == TaskStatus.notFound ||
                p?.status == TaskStatus.canceled,
          )) {
            entry.status = TaskStatus.failed;
            entry.failure = downloadFailure(
              parts.whereType<TaskRecord>().firstWhere(
                (p) =>
                    p.status == TaskStatus.failed ||
                    p.status == TaskStatus.notFound ||
                    p.status == TaskStatus.canceled,
              ),
            );
          } else if (parts.isNotEmpty &&
              parts.every((p) => p?.status == TaskStatus.complete)) {
            entry.status = TaskStatus.running;
          } else if (parts.any((p) => p?.status == TaskStatus.running)) {
            entry.status = TaskStatus.running;
          } else if (parts.any((p) => p?.status == TaskStatus.waitingToRetry)) {
            entry.status = TaskStatus.waitingToRetry;
          } else if (parts.any((p) => p?.status == TaskStatus.paused)) {
            entry.status = TaskStatus.paused;
          } else {
            entry.status = TaskStatus.enqueued;
          }
        }
        if (checkFiles) await refreshUsage();
        if (_disposed) return;
        if (!_finalizing && _foreground) {
          final ready = entries
              .where(
                (e) =>
                    !_removing.contains(e.id) &&
                    !e.ready &&
                    !e.userPaused &&
                    e.failure == null &&
                    e.tasks.isNotEmpty &&
                    e.tasks.every(
                      (t) => records[t.taskId]?.status == TaskStatus.complete,
                    ),
              )
              .firstOrNull;
          if (ready != null) unawaited(_finalize(ready));
        }
      } while (_reloadAgain && !_disposed);
      // Explicit refresh/lifecycle recovery retries a failed manifest save;
      // progress-only reloads must not repeatedly write to a failing disk.
      if ((checkedFiles && _manifestError != null) ||
          entries.any((e) => previousFailures[e.id] != e.failure)) {
        await _save();
      }
      error = null;
    } catch (_) {
      error = '暂时无法读取下载记录';
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _finalize(DownloadEntry entry) async {
    _finalizing = true;
    entry.processing = true;
    try {
      if (entry.process) {
        final processor = MediaPreparer();
        _processor = processor;
        final temporary = '${entry.directory}/video.part.mp4';
        await processor.remux(
          input: '${entry.directory}/${entry.input}',
          output: temporary,
          contentKey: entry.contentKey,
          hls: entry.input.endsWith('.m3u8'),
        );
        await File(temporary).rename(entry.output);
      }
      if (!await File(entry.output).exists() ||
          await File(entry.output).length() == 0) {
        throw const ProviderException('视频文件未完整保存');
      }
      entry.ready = true;
      entry.status = TaskStatus.complete;
      entry.progress = 1;
      await _save();
      if (entry.process) {
        for (final item in await Directory(entry.directory).list().toList()) {
          if (item.path != entry.output && item is File) await item.delete();
        }
      }
    } catch (_) {
      // A verified output stays usable if manifest saving or cleanup fails.
      if (_foreground && !entry.ready) {
        entry.failure = '视频整理失败，请重试；如空间不足请先清理设备';
        entry.status = TaskStatus.failed;
      }
    } finally {
      try {
        await _save();
      } catch (_) {
        error = '下载记录保存失败，请检查设备空间';
      }
      await _measureEntryUsage(entry);
      entry.processing = false;
      _finalizing = false;
      _processor = null;
      if (!_disposed) {
        notifyListeners();
        if (_foreground) unawaited(reload(verifyFiles: false));
      }
    }
  }

  Future<void> enqueue(Drama drama, Episode episode, int index) async {
    _requireReady();
    final identity = '${drama.key}:${episode.id}';
    if (!_enqueuing.add(identity)) return;
    Directory? staging;
    DownloadEntry? created;
    var registered = false;
    try {
      final existing = entryFor(drama, episode);
      if (existing != null &&
          !existing.complete &&
          (existing.failure != null ||
              existing.status == TaskStatus.failed ||
              existing.status == TaskStatus.canceled)) {
        await retry(existing);
        return;
      }
      if (entries.any(
        (e) =>
            e.drama.key == drama.key &&
            e.episode.id == episode.id &&
            e.status != TaskStatus.failed &&
            e.status != TaskStatus.canceled,
      )) {
        return;
      }
      final plan = await app.provider.downloadPlan(drama, episode);
      final id = '${DateTime.now().microsecondsSinceEpoch}';
      final directory = Directory('${_root!.path}/$id');
      staging = directory;
      await directory.create(recursive: true);
      for (final inline in plan.inline) {
        await File(
          '${directory.path}/${inline.name}',
        ).writeAsBytes(inline.bytes, flush: true);
      }
      final tasks = <DownloadTask>[];
      for (var i = 0; i < plan.assets.length; i++) {
        final asset = plan.assets[i];
        tasks.add(
          DownloadTask(
            taskId: '${id}_$i',
            url: asset.url,
            filename: asset.name,
            directory: 'guoguo/$id',
            baseDirectory: BaseDirectory.applicationDocuments,
            group: group,
            headers: plan.headers,
            requiresWiFi: !app.preferences.cellularDownloads,
            allowPause: true,
            retries: 3,
            updates: Updates.statusAndProgress,
            displayName: '${drama.title} · 第 ${episode.number} 集',
            metaData: id,
          ),
        );
      }
      final entry = DownloadEntry(
        id: id,
        drama: drama,
        episode: episode,
        index: index,
        directory: directory.path,
        input: plan.input,
        contentKey: plan.contentKey,
        process: plan.process,
        refreshOnResume: plan.refreshOnResume,
        assetIdentities: {
          for (final asset in plan.assets) asset.name: asset.identity,
        },
        tasks: tasks,
      );
      created = entry;
      entries.add(entry);
      try {
        await _save();
        registered = true;
      } catch (_) {
        entries.remove(entry);
        rethrow;
      }
      notifyListeners();
      for (final task in tasks) {
        if (!await driver.enqueue(task)) {
          entry.failure = '部分资源未能加入下载，请重试';
          entry.status = TaskStatus.failed;
          await _save();
          notifyListeners();
          throw const ProviderException('部分资源未能加入下载，已加入的任务会保留，请重试');
        }
      }
      await reload();
    } catch (e) {
      final message = e is FileSystemException
          ? (e.osError?.errorCode == 28
                ? '设备空间不足，请清理后重试'
                : '下载文件写入失败，请检查设备空间后重试')
          : e is ProviderException
          ? e.message
          : '下载未能完成，请检查网络和设备空间后重试';
      if (registered && created != null) {
        created.failure = message;
        created.status = TaskStatus.failed;
        try {
          await _save();
        } catch (_) {
          error = '下载记录保存失败，请检查设备空间';
        }
        if (!_disposed) notifyListeners();
      }
      throw ProviderException(message);
    } finally {
      try {
        if (!registered && staging != null && await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } finally {
        _enqueuing.remove(identity);
      }
    }
  }

  Future<void> pause(DownloadEntry entry) => _setPaused(entry, true);

  Future<void> resume(DownloadEntry entry) =>
      entry.refreshOnResume ? retry(entry) : _setPaused(entry, false);

  Future<void> _setPaused(DownloadEntry entry, bool paused) async {
    _requireReady();
    if (entry.ready || !entries.contains(entry)) return;
    if (entry.processing || !_removing.add(entry.id)) {
      throw const ProviderException('任务正在处理中，请稍候');
    }
    try {
      entry.userPaused = paused;
      entry.failure = null;
      await _save();
      for (final task in entry.tasks) {
        final record = await driver.record(task.taskId);
        if (paused) {
          if (record?.status == TaskStatus.running) {
            if (!await driver.pause(task) &&
                !await driver.cancel([task.taskId])) {
              throw const ProviderException('任务未能暂停，请稍后重试');
            }
          } else if (record?.status == TaskStatus.enqueued ||
              record?.status == TaskStatus.waitingToRetry) {
            if (!await driver.cancel([task.taskId])) {
              throw const ProviderException('排队任务未能停止，请稍后重试');
            }
          }
        } else {
          if (record?.status == TaskStatus.complete ||
              record?.status == TaskStatus.running ||
              record?.status == TaskStatus.enqueued) {
            continue;
          }
          if (record?.status == TaskStatus.paused &&
              await driver.resume(task)) {
            continue;
          }
          if (!await driver.enqueue(task)) {
            throw const ProviderException('部分资源无法恢复，请重试');
          }
        }
      }
    } catch (e) {
      entry.failure = e is ProviderException
          ? e.message
          : '下载操作失败，请检查网络和设备空间后重试';
      entry.status = TaskStatus.failed;
      await _save();
      rethrow;
    } finally {
      _removing.remove(entry.id);
      await reload(verifyFiles: false);
    }
  }

  DownloadEntry? entryFor(Drama drama, Episode episode) => entries
      .where((e) => e.drama.key == drama.key && e.episode.id == episode.id)
      .firstOrNull;

  /// Remove only this application's unregistered numeric task directories.
  Future<void> cleanupOrphans() async {
    if (_root == null || !await _root!.exists()) return;
    final known = entries.map((e) => e.id).toSet();
    final records = await driver.records();
    if (_disposed) return;
    for (final record in records) {
      if (_disposed) return;
      if (!known.contains(record.task.metaData)) {
        if (!await driver.cancel([record.taskId])) {
          throw const ProviderException('旧下载任务尚未停止，请稍后重试清理');
        }
        if (_disposed) return;
        await driver.deleteRecord(record.taskId);
      }
    }
    await for (final item in _root!.list(followLinks: false)) {
      if (_disposed) return;
      final name = item.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (item is Directory &&
          RegExp(r'^\d+$').hasMatch(name) &&
          !known.contains(name)) {
        await item.delete(recursive: true);
      }
    }
  }

  Future<void> retry(DownloadEntry entry) async {
    _requireReady();
    await _retry(entry);
  }

  Future<void> _retry(DownloadEntry entry) async {
    if (entry.ready || !entries.contains(entry)) return;
    if (entry.processing || !_removing.add(entry.id)) {
      throw const ProviderException('任务正在处理中，请稍候');
    }
    try {
      final complete = <String>{};
      for (final task in entry.tasks) {
        final record = await driver.record(task.taskId);
        if (_disposed) return;
        final file = File('${entry.directory}/${task.filename}');
        if (record?.status == TaskStatus.complete &&
            await file.exists() &&
            await file.length() > 0) {
          complete.add(task.taskId);
        }
      }
      if (_disposed) return;
      if (complete.length != entry.tasks.length) {
        // Resolve first: an expired URL or provider error never removes progress.
        final plan = await app.provider.downloadPlan(
          entry.drama,
          entry.episode,
        );
        if (_disposed) return;
        final assets = {for (final asset in plan.assets) asset.name: asset.url};
        final identities = {
          for (final asset in plan.assets) asset.name: asset.identity,
        };
        if (plan.input != entry.input ||
            plan.process != entry.process ||
            plan.contentKey != entry.contentKey ||
            assets.length != entry.tasks.length ||
            entry.tasks.any((t) => !assets.containsKey(t.filename))) {
          throw const ProviderException('资源结构已变化，旧文件已保留；请删除此任务后重新下载');
        }
        // Do not mix changed playlists, keys or segment ordering with old parts.
        for (final inline in plan.inline) {
          if (_disposed) return;
          final file = File('${entry.directory}/${inline.name}');
          if (!await file.exists() ||
              !listEquals(await file.readAsBytes(), inline.bytes)) {
            throw const ProviderException('资源清单已变化，旧文件已保留；请删除此任务后重新下载');
          }
        }
        for (final task in entry.tasks.where(
          (t) => complete.contains(t.taskId),
        )) {
          if (identities[task.filename] !=
              (entry.assetIdentities[task.filename] ?? task.url)) {
            throw const ProviderException('已下载资源地址发生变化，旧文件已保留；请删除此任务后重新下载');
          }
        }
        final replacements = entry.tasks
            .map(
              (task) => complete.contains(task.taskId)
                  ? task
                  : task.copyWith(
                      url: assets[task.filename],
                      headers: plan.headers,
                    ),
            )
            .toList();
        if (!await driver.cancel(
          entry.tasks
              .where((t) => !complete.contains(t.taskId))
              .map((t) => t.taskId),
        )) {
          throw const ProviderException('旧下载尚未停止，已保留进度，请稍后重试');
        }
        if (_disposed) return;
        entry.tasks
          ..clear()
          ..addAll(replacements);
        entry.assetIdentities
          ..clear()
          ..addAll(identities);
        entry.refreshOnResume = plan.refreshOnResume;
        entry.failure = null;
        entry.userPaused = false;
        await _save();
        for (final task in entry.tasks.where(
          (t) => !complete.contains(t.taskId),
        )) {
          if (_disposed) return;
          if (!await driver.enqueue(task)) {
            throw const ProviderException('部分资源无法恢复，已完成分片会保留');
          }
        }
      }
      if (_disposed) return;
      entry.failure = null;
      entry.userPaused = false;
      await _save();
    } catch (e) {
      if (_disposed) return;
      entry.failure = e is ProviderException
          ? e.message
          : '重试失败，已下载文件已保留；请检查网络和设备空间';
      entry.status = TaskStatus.failed;
      try {
        await _save();
      } catch (_) {
        error = '下载记录保存失败，请检查设备空间';
      }
      rethrow;
    } finally {
      _removing.remove(entry.id);
      await reload();
    }
  }

  Future<void> remove(DownloadEntry entry) async {
    _requireReady();
    if (entry.processing) throw const ProviderException('正在整理视频，请稍候再删除');
    if (!entries.contains(entry)) return;
    if (!_removing.add(entry.id)) {
      throw const ProviderException('任务正在处理中，请稍后再删除');
    }
    var deletingFiles = false;
    var filesRemoved = false;
    try {
      if (entry.tasks.isNotEmpty &&
          !await driver.cancel(entry.tasks.map((t) => t.taskId))) {
        throw const ProviderException('后台下载尚未停止，文件与记录已保留，请稍后再删除');
      }
      final directory = Directory(entry.directory);
      deletingFiles = true;
      if (await directory.exists()) await directory.delete(recursive: true);
      filesRemoved = true;
      for (final task in entry.tasks) {
        await driver.deleteRecord(task.taskId);
      }
      entries.remove(entry);
      try {
        await _save();
      } catch (_) {
        entries.add(entry);
        entry.ready = false;
        entry.failure = '文件已清理，但记录保存失败，请重试删除';
        entry.status = TaskStatus.failed;
        rethrow;
      }
      bytesByEntry.remove(entry.id);
    } catch (_) {
      if (deletingFiles && entries.contains(entry)) {
        entry.ready = false;
        entry.failure = filesRemoved
            ? '文件已清理，但记录未能移除，请重试删除'
            : '删除未完成，部分文件可能已清理，请重试删除';
        entry.status = TaskStatus.failed;
        try {
          await _save();
        } catch (_) {
          error = '下载记录保存失败，请检查设备空间';
        }
      }
      rethrow;
    } finally {
      _removing.remove(entry.id);
      if (entries.contains(entry)) await _measureEntryUsage(entry);
      if (!_disposed) notifyListeners();
    }
  }

  /// Explicit refreshes scan saved files; progress events only read task records.
  Future<void> refreshUsage() {
    if (_disposed) return Future.value();
    if (_usageRefresh != null) {
      _usageAgain = true;
      return _usageRefresh!;
    }
    final future = _measureUsage();
    _usageRefresh = future;
    return future;
  }

  Future<void> _measureUsage() async {
    // Start after refreshUsage has registered the shared future.
    await Future<void>.delayed(Duration.zero);
    if (!_disposed) notifyListeners();
    try {
      try {
        // Files can be measured before native task recovery, but only after
        // the saved download list has supplied the scopes to scan.
        await _manifestLoad;
      } catch (_) {
        usageError = '下载记录暂无法读取，文件占用尚未统计';
        return;
      }
      if (_disposed) return;
      do {
        _usageAgain = false;
        usageError = null;
        for (final entry in entries.toList()) {
          await _measureEntryUsage(entry);
        }
        bytesByEntry.removeWhere((id, _) => !entries.any((e) => e.id == id));
      } while (_usageAgain && !_disposed);
    } finally {
      _usageRefresh = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _measureEntryUsage(DownloadEntry entry) async {
    final bytes = await directoryFileBytes(Directory(entry.directory));
    if (!entries.contains(entry)) return;
    if (bytes == null) {
      bytesByEntry.remove(entry.id);
      usageError = '部分文件占用暂时无法统计，下拉可重新统计';
    } else {
      bytesByEntry[entry.id] = bytes;
    }
  }

  int? bytesFor(Iterable<DownloadEntry> items) {
    var total = 0;
    for (final entry in items) {
      final bytes = bytesByEntry[entry.id];
      if (bytes == null) return null;
      total += bytes;
    }
    return total;
  }

  Future<String?> localFile(Drama drama, Episode episode) async {
    // An immediate continue action must not miss files still being read from
    // the manifest, or wait for native task restoration to finish.
    try {
      await _manifestLoad;
    } catch (_) {
      // A manifest failure affects downloads; online playback remains usable.
    }
    if (_disposed) return null;
    final found = entries
        .where(
          (e) =>
              e.ready && e.drama.key == drama.key && e.episode.id == episode.id,
        )
        .firstOrNull;
    return found != null && await File(found.output).exists()
        ? found.output
        : null;
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _refreshTimer?.cancel();
    unawaited(_processor?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
