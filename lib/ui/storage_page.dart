import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../data/download_store.dart';
import '../data/storage_manager.dart';
import 'detail_page.dart';
import 'downloads_page.dart';

class StoragePage extends StatefulWidget {
  const StoragePage({
    super.key,
    required this.store,
    required this.downloads,
    this.manager,
  });

  final AppStore store;
  final DownloadStore downloads;
  final StorageManager? manager;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  late StorageManager _manager;
  StorageUsage? _usage;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _generation++;
    _manager = widget.manager ?? StorageManager(widget.store, widget.downloads);
    _usage = null;
    _busy = false;
    _error = null;
    unawaited(_run(_manager));
  }

  @override
  void didUpdateWidget(StoragePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store ||
        oldWidget.downloads != widget.downloads ||
        oldWidget.manager != widget.manager) {
      _bind();
    }
  }

  bool _current(StorageManager owner, int generation) =>
      mounted && owner == _manager && generation == _generation;

  Future<void> _run(
    StorageManager owner, {
    int? generation,
    Future<void> Function()? cleanup,
  }) async {
    final token = generation ?? _generation;
    if (!_current(owner, token) || _busy) return;
    if (cleanup != null && ModalRoute.of(context)?.isCurrent == false) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (cleanup != null) await cleanup();
      if (!_current(owner, token)) return;
      final usage = await owner.measure();
      if (!_current(owner, token)) return;
      setState(() => _usage = usage);
      if (mounted &&
          cleanup != null &&
          ModalRoute.of(context)?.isCurrent != false) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('清理完成，已重新统计占用')));
      }
    } catch (_) {
      if (_current(owner, token)) {
        setState(() {
          _error = cleanup == null ? '占用暂时无法更新，请稍后重新统计' : '清理未完成，请检查可用空间后重试';
        });
      }
    } finally {
      if (_current(owner, token)) setState(() => _busy = false);
    }
  }

  String _size(int? bytes) => bytes == null
      ? (_usage == null && _busy ? '正在统计…' : '暂无法统计')
      : formatDownloadBytes(bytes);

  Widget _scope(String title, int? bytes, String description, Widget action) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                _size(bytes),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(description),
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerLeft, child: action),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final owner = _manager;
    final generation = _generation;
    final store = widget.store, downloads = widget.downloads;
    final playback = _usage?.playback;
    return Scaffold(
      appBar: AppBar(
        title: const Text('存储管理'),
        actions: [
          IconButton(
            tooltip: '重新统计',
            onPressed: _busy ? null : () => _run(owner, generation: generation),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: RefreshIndicator(
            onRefresh: () => _run(owner, generation: generation),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '统计下列已保存文件的大小，不含系统下载临时文件、应用安装包、内存和其他应用数据。使用期间占用会变化，清理后也可能重新生成缓存。',
                ),
                const SizedBox(height: 12),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_error!),
                  ),
                _scope(
                  '下载文件',
                  _usage?.downloadBytes,
                  '包含下载列表中视频与已保存的临时文件。删除视频请在下载页按剧或分集操作。',
                  OutlinedButton.icon(
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('管理下载'),
                    onPressed: _busy
                        ? null
                        : () {
                            if (!_current(owner, generation) ||
                                _busy ||
                                ModalRoute.of(context)?.isCurrent == false) {
                              return;
                            }
                            Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (routeContext) => Scaffold(
                                  appBar: AppBar(title: const Text('下载')),
                                  body: DownloadsPage(
                                    store: store,
                                    downloads: downloads,
                                    onOpen: (drama) => openDrama(
                                      routeContext,
                                      store,
                                      downloads,
                                      drama,
                                    ),
                                  ),
                                ),
                              ),
                            ).then((_) {
                              if (_current(owner, generation)) {
                                unawaited(_run(owner, generation: generation));
                              }
                            });
                          },
                  ),
                ),
                _scope(
                  '播放临时文件',
                  playback?.totalBytes,
                  '正在使用：${_size(playback?.activeBytes)}\n可清理：${_size(playback?.unusedBytes)}\n只清理已释放的播放会话，正在准备、播放和投屏的文件会保留。',
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            owner,
                            generation: generation,
                            cleanup: owner.clearUnusedPlayback,
                          ),
                    child: const Text('清理闲置播放文件'),
                  ),
                ),
                _scope(
                  '封面文件',
                  _usage?.coverBytes,
                  '统计已保存的封面图片，不含缓存索引。清理后按需重新加载，部分文件可能仍有占用。',
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            owner,
                            generation: generation,
                            cleanup: owner.clearCovers,
                          ),
                    child: const Text('清理封面缓存'),
                  ),
                ),
                _scope(
                  '目录与分集缓存',
                  _usage?.catalogBytes,
                  '清理本地保存的浏览、搜索、推荐、榜单和分集缓存。当前已加载内容可继续使用；重启后需要联网重新加载。收藏、历史、设置和下载视频会保留。',
                  OutlinedButton(
                    onPressed: _busy || !owner.canClearCatalog
                        ? null
                        : () => _run(
                            owner,
                            generation: generation,
                            cleanup: owner.clearCatalog,
                          ),
                    child: const Text('清理目录缓存'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
