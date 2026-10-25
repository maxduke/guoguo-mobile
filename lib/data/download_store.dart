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
import 'download_entry.dart';
import 'download_manifest_recovery.dart';
import 'download_task_updates.dart';
export 'download_entry.dart';

class _DownloadSubmission {
  final drained = Completer<void>();
  bool stopped = false;
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
  final _taskUpdates = DownloadTaskUpdates();
  final _taskOwners = <String, DownloadEntry>{};
  final _taskDefinitions = <String, DownloadTask>{};
  bool _verifyFiles = false;
  final Set<String> _removing = {};
  final Map<String, _DownloadSubmission> _submissions = {};
  bool _loading = false,
      _reloadAgain = false,
      _disposed = false,
      _foreground = true,
      _finalizing = false;
  MediaPreparer? _processor;
  final Set<String> _enqueuing = {};
  final Map<String, int> bytesByEntry = {};
  Set<String> _protectedDirectories = {};
  bool _preserveUnknownDirectories = false;
  String? get recoveryNotice => !_preserveUnknownDirectories
      ? null
      : '下载记录已修复，${_protectedDirectories.isEmpty ? '未识别的视频文件' : '${_protectedDirectories.length} 个未识别的目录'}会继续保留，不自动清理';
  DownloadManifestRecovery? get manifestRecovery =>
      !manifestLoaded &&
          initializationError != null &&
          _storage is FileStorage &&
          _root != null
      ? DownloadManifestRecovery(_storage! as FileStorage, _root!)
      : null;
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
      final retained = protectedDownloadDirectories(state);
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
      _protectedDirectories = retained;
      _preserveUnknownDirectories = state['preserveUnknownDirectories'] == true;
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
      _subscription = driver.updates.listen(_queueTaskUpdate);
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
        if (_protectedDirectories.isNotEmpty)
          'protectedDirectories': _protectedDirectories.toList(),
        if (_preserveUnknownDirectories) 'preserveUnknownDirectories': true,
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

  void _indexTasks(DownloadEntry entry) {
    for (final task in entry.tasks) {
      _taskOwners[task.taskId] = entry;
      _taskDefinitions[task.taskId] = task;
    }
  }

  void _forgetTasks(DownloadEntry entry) {
    for (final task in entry.tasks) {
      _taskOwners.remove(task.taskId);
      _taskDefinitions.remove(task.taskId);
      _taskUpdates.resetTask(task.taskId);
    }
  }

  void _queueTaskUpdate(TaskUpdate update) {
    if (_disposed || !initialized || update.task.group != group) return;
    final owner = _taskOwners[update.task.taskId];
    final task = _taskDefinitions[update.task.taskId];
    if (owner == null ||
        task == null ||
        owner.ready ||
        _removing.contains(owner.id) ||
        task.url != update.task.url) {
      return;
    }
    _taskUpdates.add(update);
    _scheduleTaskUpdates();
  }

  void _scheduleTaskUpdates() {
    if (_disposed || !_taskUpdates.hasPending) return;
    _refreshTimer ??= Timer(const Duration(milliseconds: 300), () {
      _refreshTimer = null;
      unawaited(_applyTaskUpdates());
    });
  }

  Future<void> _applyTaskUpdates() async {
    if (_disposed || !_taskUpdates.hasPending) return;
    if (_loading) {
      _scheduleTaskUpdates();
      return;
    }
    _loading = true;
    var changed = false, save = false;
    try {
      final affected = _taskUpdates
          .apply()
          .map((id) => _taskOwners[id])
          .whereType<DownloadEntry>()
          .toSet();
      for (final entry in affected) {
        if (entry.ready || _removing.contains(entry.id)) continue;
        final previous = entry.failure;
        updateDownloadEntry(entry, _taskUpdates.records);
        save = save || previous != entry.failure;
        changed = true;
      }
      if (save) await _save();
      if (!_disposed && !_finalizing && _foreground) {
        final ready = affected
            .where(
              (e) =>
                  !e.ready &&
                  !e.userPaused &&
                  e.failure == null &&
                  !_removing.contains(e.id) &&
                  e.awaitingProcessing,
            )
            .firstOrNull;
        if (ready != null) unawaited(_finalize(ready));
      }
    } catch (_) {
      error = '下载状态更新暂未完成，请下拉刷新重试';
    } finally {
      _loading = false;
      if (!_disposed) {
        if (changed) notifyListeners();
        if (_reloadAgain) unawaited(reload(verifyFiles: false));
        _scheduleTaskUpdates();
      }
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
        final snapshot = await driver.records();
        if (_disposed) return;
        _taskOwners.clear();
        _taskDefinitions.clear();
        for (final entry in entries) {
          _indexTasks(entry);
        }
        _taskUpdates.replace(snapshot, _taskOwners.keys.toSet());
        final records = _taskUpdates.records;
        for (final entry in entries.toList()) {
          if (_removing.contains(entry.id)) continue;
          if (entry.ready) {
            final valid = !checkFiles || await _hasOutput(entry);
            if (_disposed) return;
            if (!entries.contains(entry) || _removing.contains(entry.id)) {
              continue;
            }
            if (valid) {
              entry.status = TaskStatus.complete;
              entry.progress = 1;
              continue;
            }
            _invalidateOutput(entry);
            continue;
          }
          updateDownloadEntry(entry, records);
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
      if (!await _hasOutput(entry)) {
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
    _DownloadSubmission? submission;
    var registered = false;
    var submitted = false;
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
      if (_disposed) return;
      final id = '${DateTime.now().microsecondsSinceEpoch}';
      final directory = Directory('${_root!.path}/$id');
      staging = directory;
      await directory.create(recursive: true);
      for (final inline in plan.inline) {
        if (_disposed) return;
        await File(
          '${directory.path}/${inline.name}',
        ).writeAsBytes(inline.bytes, flush: true);
      }
      if (_disposed) return;
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
      submission = _DownloadSubmission();
      _submissions[id] = submission;
      entries.add(entry);
      _indexTasks(entry);
      try {
        await _save();
        registered = true;
      } catch (_) {
        entries.remove(entry);
        _forgetTasks(entry);
        rethrow;
      }
      if (!_disposed) notifyListeners();
      for (final task in tasks) {
        if (_disposed || submission.stopped || !entries.contains(entry)) return;
        if (!await driver.enqueue(task)) {
          if (_disposed || submission.stopped) return;
          throw const ProviderException('部分资源未能加入下载，已加入的任务会保留，请重试');
        }
      }
      if (_disposed || submission.stopped) return;
      submitted = true;
      await reload();
    } catch (e) {
      final message = e is FileSystemException
          ? (e.osError?.errorCode == 28
                ? '设备空间不足，请清理后重试'
                : '下载文件写入失败，请检查设备空间后重试')
          : e is ProviderException
          ? e.message
          : '下载未能完成，请检查网络和设备空间后重试';
      if (registered && created != null && entries.contains(created)) {
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
        if (_disposed && registered && !submitted && created != null) {
          // Closing the store must not leave a partly submitted batch running.
          // Other, already submitted downloads continue in the native queue.
          created.userPaused = true;
          try {
            if (!await driver.cancel(created.tasks.map((t) => t.taskId))) {
              created.failure = '下载提交已中断，后台任务未能停止，请重试';
            }
            await _save();
          } catch (_) {
            // The saved entry retains every task ID for the next reconciliation.
          }
        }
        if (!registered && staging != null && await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } finally {
        if (created != null && submission != null) {
          _submissions.remove(created.id);
          submission.drained.complete();
        }
        _enqueuing.remove(identity);
      }
    }
  }

  Future<void> pause(DownloadEntry entry) => _setPaused(entry, true);

  Future<void> resume(DownloadEntry entry) =>
      entry.refreshOnResume ? retry(entry) : _setPaused(entry, false);

  Future<void> _stopSubmission(DownloadEntry entry) async {
    final submission = _submissions[entry.id];
    if (submission == null) return;
    submission.stopped = true;
    await submission.drained.future;
  }

  Future<void> _setPaused(DownloadEntry entry, bool paused) async {
    _requireReady();
    if (entry.ready || !entries.contains(entry)) return;
    if (entry.processing || !_removing.add(entry.id)) {
      throw const ProviderException('任务正在处理中，请稍候');
    }
    try {
      await _stopSubmission(entry);
      if (_disposed || !entries.contains(entry)) return;
      entry.userPaused = paused;
      entry.failure = null;
      await _save();
      for (final task in entry.tasks) {
        if (_disposed) return;
        final record = await driver.record(task.taskId);
        if (_disposed) return;
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
          !known.contains(name) &&
          !_preserveUnknownDirectories &&
          !_protectedDirectories.contains(name)) {
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
      await _stopSubmission(entry);
      if (_disposed || !entries.contains(entry)) return;
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
        for (final task in entry.tasks) {
          if (!complete.contains(task.taskId)) {
            _taskUpdates.resetTask(task.taskId);
          }
        }
        _indexTasks(entry);
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
      await _stopSubmission(entry);
      if (_disposed || !entries.contains(entry)) return;
      if (entry.tasks.isNotEmpty &&
          !await driver.cancel(entry.tasks.map((t) => t.taskId))) {
        entry.failure = '后台下载尚未停止，请重试删除或恢复下载';
        entry.status = TaskStatus.failed;
        await _save();
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
      _forgetTasks(entry);
      try {
        await _save();
      } catch (_) {
        entries.add(entry);
        _indexTasks(entry);
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

  /// Explicit refreshes scan saved files; progress events use cached task records.
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
        final currentIds = entries.map((e) => e.id).toSet();
        bytesByEntry.removeWhere((id, _) => !currentIds.contains(id));
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
    if (found == null || _removing.contains(found.id)) return null;
    final valid = await _hasOutput(found);
    if (_disposed || !entries.contains(found) || _removing.contains(found.id)) {
      return null;
    }
    if (valid) return found.ready ? found.output : null;
    _invalidateOutput(found);
    try {
      await _save();
    } catch (_) {
      // The manifest error remains actionable; an invalid path is never returned.
    }
    if (!_disposed) notifyListeners();
    return null;
  }

  Future<bool> _hasOutput(DownloadEntry entry) async {
    try {
      final stat = await File(entry.output).stat();
      return stat.type == FileSystemEntityType.file && stat.size > 0;
    } on FileSystemException {
      return false;
    }
  }

  void _invalidateOutput(DownloadEntry entry) {
    entry.ready = false;
    entry.failure = '视频文件已丢失或为空，请重新下载';
    entry.status = TaskStatus.failed;
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
