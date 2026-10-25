import 'package:background_downloader/background_downloader.dart';
import '../domain/models.dart';

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

void updateDownloadEntry(DownloadEntry entry, Map<String, TaskRecord> records) {
  final parts = entry.tasks.map((t) => records[t.taskId]).toList();
  double partProgress(TaskRecord? part) => part?.status == TaskStatus.complete
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
      parts.isNotEmpty && parts.every((p) => p?.status == TaskStatus.complete);
  if (entry.failure != null) {
    entry.status = TaskStatus.failed;
    return;
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
