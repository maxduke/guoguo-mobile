import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';
import '../platform/media_preparer.dart';
import '../platform/provider_client.dart';
import 'app_store.dart';
import 'storage.dart';

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
  });
  final String id, directory, input, contentKey;
  final Drama drama;
  final Episode episode;
  final int index;
  final bool process;
  final List<DownloadTask> tasks;
  bool ready, userPaused, processing = false;
  TaskStatus status = TaskStatus.enqueued;
  double progress = 0;
  String? failure;
  bool get complete => ready;
  String get output => '$directory/${process ? 'video.mp4' : input}';
  String get label =>
      failure ??
      (processing
          ? '正在整理视频'
          : switch (status) {
              TaskStatus.enqueued => '等待下载',
              TaskStatus.running => '下载中',
              TaskStatus.complete => '已完成',
              TaskStatus.paused => '已暂停',
              TaskStatus.waitingToRetry => '等待重试',
              TaskStatus.failed => '下载失败',
              TaskStatus.canceled => '已取消',
              TaskStatus.notFound => '资源已失效',
            });
  Map<String, dynamic> toJson() => {
    'id': id,
    'drama': drama.toJson(),
    'episode': episode.raw,
    'index': index,
    'directory': directory,
    'input': input,
    'contentKey': contentKey,
    'process': process,
    'tasks': tasks.map((t) => t.toJson()).toList(),
    'ready': ready,
    'userPaused': userPaused,
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
    tasks: (json['tasks'] as List)
        .map((t) => DownloadTask.fromJson(Map<String, dynamic>.from(t as Map)))
        .toList(),
    ready: json['ready'] == true,
    userPaused: json['userPaused'] == true,
  );
}

class DownloadStore extends ChangeNotifier with WidgetsBindingObserver {
  DownloadStore(this.app);
  final AppStore app;
  final FileDownloader downloader = FileDownloader();
  List<DownloadEntry> entries = [];
  StreamSubscription<TaskUpdate>? _subscription;
  LocalStorage? _storage;
  Directory? _root;
  String? error;
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
  static const group = 'guoguo';

  Future<void> initialize() async {
    _root = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/guoguo',
    );
    await _root!.create(recursive: true);
    _storage = FileStorage(
      Directory('${(await getApplicationSupportDirectory()).path}/downloads'),
    );
    final state = await _storage!.read();
    if (state != null) {
      entries = (state['jobs'] as List)
          .map(
            (v) => DownloadEntry.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
      // Application container paths can change after an iOS update/reinstall.
      entries = entries.map((entry) {
        final json = entry.toJson();
        json['directory'] = '${_root!.path}/${entry.id}';
        return DownloadEntry.fromJson(json);
      }).toList();
    }
    WidgetsBinding.instance.addObserver(this);
    _subscription = downloader.updates.listen((_) {
      _refreshTimer ??= Timer(const Duration(milliseconds: 300), () {
        _refreshTimer = null;
        unawaited(reload(verifyFiles: false));
      });
    });
    downloader.configureNotificationForGroup(
      group,
      running: const TaskNotification('正在下载 {displayName}', '{progress}'),
      error: const TaskNotification('下载未完成', '{displayName}'),
      paused: const TaskNotification('下载已暂停', '{displayName}'),
      progressBar: true,
    );
    await downloader.trackTasks();
    await downloader.requireWiFi(
      app.cellularDownloads ? RequireWiFi.forNoTasks : RequireWiFi.forAllTasks,
    );
    await downloader.start();
    for (final entry in entries.where((e) => !e.ready && !e.userPaused)) {
      for (final task in entry.tasks) {
        if (await downloader.database.recordForId(task.taskId) == null) {
          await downloader.enqueue(task);
        }
      }
    }
    await reload();
  }

  Future<void> _save() async => _storage?.write({
    'version': 1,
    'jobs': entries.map((e) => e.toJson()).toList(),
  });
  Future<void> setCellular(bool enabled) async {
    final ok = await downloader.requireWiFi(
      enabled ? RequireWiFi.forNoTasks : RequireWiFi.forAllTasks,
    );
    if (!ok) throw const ProviderException('网络规则未能更新，请重试');
    await app.setNetwork(downloads: enabled);
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
    if (_disposed || _storage == null) return;
    if (_loading) {
      _reloadAgain = true;
      return;
    }
    _loading = true;
    try {
      do {
        _reloadAgain = false;
        final checkFiles = _verifyFiles;
        _verifyFiles = false;
        final records = {
          for (final r in await downloader.database.allRecords(group: group))
            r.taskId: r,
        };
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
          if (entry.failure != null) {
            entry.status = TaskStatus.failed;
            continue;
          }
          final parts = entry.tasks.map((t) => records[t.taskId]).toList();
          entry.progress = parts.isEmpty
              ? 0
              : parts.fold<double>(
                      0,
                      (total, p) => total + (p?.progress ?? 0).clamp(0, 1),
                    ) /
                    parts.length;
          if (entry.userPaused) {
            entry.status = TaskStatus.paused;
          } else if (parts.any(
            (p) =>
                p?.status == TaskStatus.failed ||
                p?.status == TaskStatus.notFound ||
                p?.status == TaskStatus.canceled,
          )) {
            entry.status = TaskStatus.failed;
          } else if (parts.isNotEmpty &&
              parts.every((p) => p?.status == TaskStatus.complete)) {
            entry.status = TaskStatus.running;
          } else if (parts.any((p) => p?.status == TaskStatus.running)) {
            entry.status = TaskStatus.running;
          } else {
            entry.status = TaskStatus.enqueued;
          }
        }
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
      if (_foreground) {
        entry.failure = '视频整理失败，请重新下载';
        entry.status = TaskStatus.failed;
      }
    } finally {
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
    if (_root == null) throw const ProviderException('下载组件尚未就绪，请重新打开应用');
    final identity = '${drama.key}:${episode.id}';
    if (!_enqueuing.add(identity)) return;
    try {
      if (entries.any(
        (e) =>
            e.drama.key == drama.key &&
            e.episode.id == episode.id &&
            e.status != TaskStatus.failed &&
            e.status != TaskStatus.canceled,
      )) {
        return;
      }
      final plan = await app.provider.call('downloadPlan', {
        'id': drama.id,
        'chapter': episode.raw,
      });
      final id = '${DateTime.now().microsecondsSinceEpoch}';
      final directory = Directory('${_root!.path}/$id');
      await directory.create(recursive: true);
      String safeName(Object? raw) {
        final name = raw as String;
        if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(name) ||
            name == '.' ||
            name == '..') {
          throw const FormatException('无效的资源文件名');
        }
        return name;
      }

      for (final inline in plan['inline'] as List) {
        await File(
          '${directory.path}/${safeName(inline['name'])}',
        ).writeAsBytes(base64Decode(inline['body'] as String), flush: true);
      }
      final assets = plan['assets'] as List;
      if (assets.isEmpty) throw const ProviderException('未找到可下载资源');
      final tasks = <DownloadTask>[];
      for (var i = 0; i < assets.length; i++) {
        final asset = assets[i] as Map;
        tasks.add(
          DownloadTask(
            taskId: '${id}_$i',
            url: asset['url'] as String,
            filename: safeName(asset['name']),
            directory: 'guoguo/$id',
            baseDirectory: BaseDirectory.applicationDocuments,
            group: group,
            headers: Map<String, String>.from(plan['headers'] as Map),
            requiresWiFi: !app.cellularDownloads,
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
        input: safeName(plan['input']),
        contentKey: plan['contentKey'] as String? ?? '',
        process: plan['process'] == true,
        tasks: tasks,
      );
      entries.add(entry);
      await _save();
      notifyListeners();
      for (final task in tasks) {
        if (!await downloader.enqueue(task)) {
          entry.failure = '部分资源未能加入下载，请重试';
          entry.status = TaskStatus.failed;
          break;
        }
      }
      await reload();
    } finally {
      _enqueuing.remove(identity);
    }
  }

  Future<void> pause(DownloadEntry entry) async {
    if (entry.ready) return;
    if (entry.processing) throw const ProviderException('正在整理视频，请稍候');
    entry.userPaused = true;
    await _save();
    for (final task in entry.tasks) {
      final record = await downloader.database.recordForId(task.taskId);
      if (record?.status == TaskStatus.running) {
        if (!await downloader.pause(task)) await downloader.cancel(task);
      } else if (record?.status == TaskStatus.enqueued ||
          record?.status == TaskStatus.waitingToRetry) {
        await downloader.cancel(task);
      }
    }
    await reload();
  }

  Future<void> resume(DownloadEntry entry) async {
    if (entry.ready) return;
    if (entry.processing) throw const ProviderException('正在整理视频，请稍候');
    entry.userPaused = false;
    entry.failure = null;
    await _save();
    for (final task in entry.tasks) {
      final record = await downloader.database.recordForId(task.taskId);
      if (record?.status == TaskStatus.complete ||
          record?.status == TaskStatus.running) {
        continue;
      }
      if (record?.status == TaskStatus.paused &&
          await downloader.resume(task)) {
        continue;
      }
      if (!await downloader.enqueue(task)) {
        throw const ProviderException('部分资源无法恢复，请重试');
      }
    }
    await reload();
  }

  Future<void> retry(DownloadEntry entry) async {
    await remove(entry);
    await enqueue(entry.drama, entry.episode, entry.index);
  }

  Future<void> remove(DownloadEntry entry) async {
    if (entry.processing) throw const ProviderException('正在整理视频，请稍候再删除');
    if (!_removing.add(entry.id)) return;
    try {
      await downloader.cancelTasksWithIds(entry.tasks.map((t) => t.taskId));
      for (final task in entry.tasks) {
        await downloader.database.deleteRecordWithId(task.taskId);
      }
      final directory = Directory(entry.directory);
      if (await directory.exists()) await directory.delete(recursive: true);
      entries.remove(entry);
      await _save();
    } finally {
      _removing.remove(entry.id);
      if (!_disposed) notifyListeners();
    }
  }

  Future<String?> localFile(Drama drama, Episode episode) async {
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

  Future<int> usedBytes() async {
    if (_root == null || !await _root!.exists()) return 0;
    var bytes = 0;
    await for (final file in _root!.list(recursive: true, followLinks: false)) {
      if (file is File) {
        try {
          bytes += await file.length();
        } on FileSystemException {
          // Downloads can be removed while space usage is being calculated.
          if (await file.exists()) rethrow;
        }
      }
    }
    return bytes;
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
