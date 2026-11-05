import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/provider_client.dart';

class HuangguoLinesPage extends StatefulWidget {
  const HuangguoLinesPage({super.key, required this.provider});
  final ProviderClient provider;

  @override
  State<HuangguoLinesPage> createState() => _HuangguoLinesPageState();
}

class _HuangguoLinesPageState extends State<HuangguoLinesPage> {
  List<({String url, String host})> _lines = const [];
  final _results = <String, _LineResult>{};
  String _selected = '';
  String? _error, _warning, _probing;
  bool _loading = false, _saving = false;
  bool get _busy => _loading || _saving || _probing != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _install(Map<String, dynamic> data) {
    final lines = (data['items'] as List)
        .map(
          (item) => (
            url: (item as Map)['url'] as String,
            host: item['host'] as String,
          ),
        )
        .toList();
    final selected = data['selected'] as String;
    final warning = data['warning'] as String?;
    setState(() {
      _lines = lines;
      _selected = selected;
      _warning = warning?.isNotEmpty == true ? warning : null;
      _results.removeWhere((url, _) => !lines.any((line) => line.url == url));
    });
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.provider.call('huangguoLines', {
        'refresh': true,
        'timeoutMs': 10000,
      });
      if (mounted) _install(data);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = providerFailureMessage(error, '线路列表暂时无法加载，请重试'),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(String url) async {
    if (_busy || url == _selected) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final data = await widget.provider.call('huangguoLineSelect', {
        'url': url,
      });
      if (mounted) _install(data);
    } catch (error) {
      if (mounted) {
        setState(() => _error = providerFailureMessage(error, '线路设置未保存，请重试'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _probe(String url) async {
    if (_busy) return;
    setState(() {
      _probing = url;
      _error = null;
    });
    try {
      final data = await widget.provider.call('huangguoLineProbe', {
        'url': url,
        'timeoutMs': 10000,
      });
      final result = _LineResult.fromJson(data);
      if (mounted) setState(() => _results[url] = result);
    } catch (error) {
      if (mounted) {
        setState(() => _error = providerFailureMessage(error, '线路检测未完成，请重试'));
      }
    } finally {
      if (mounted) setState(() => _probing = null);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(
        text: const JsonEncoder.withIndent('  ').convert({
          'format': 'guoguo.huangguo-lines',
          'version': 1,
          'items': [
            for (final line in _lines)
              if (_results[line.url] case final result?)
                {'host': line.host, ...result.toJson()},
          ],
        }),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('线路诊断已复制')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('黄果线路'),
      actions: [
        IconButton(
          tooltip: '刷新官方线路',
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '复制线路诊断',
          onPressed: _results.isEmpty ? null : _copy,
          icon: const Icon(Icons.copy_outlined),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('用于黄果 AI 子站。切换后刷新栏目或重新打开剧集即可使用；正在播放与下载的任务继续运行。'),
        const SizedBox(height: 12),
        const Text('检测会读取一条目录数据，不播放视频。接口通过不代表每一集都能播放，结果仅供选择线路时参考。'),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            title: const Text('自动选择'),
            subtitle: const Text('使用官网发布的线路'),
            selected: _selected.isEmpty,
            trailing: _selected.isEmpty
                ? const Icon(Icons.check)
                : const Icon(Icons.chevron_right),
            onTap: _busy ? null : () => _select(''),
          ),
        ),
        if (_loading || _saving) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_warning != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_warning!),
          ),
        if (!_loading && _lines.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('暂未取得官方线路，请刷新重试。'),
          ),
        for (final line in _lines)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.host,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _probing == line.url
                        ? '正在检测目录接口…'
                        : _results[line.url]?.label ?? '尚未检测',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _busy ? null : () => _probe(line.url),
                        child: Text(
                          _results.containsKey(line.url) ? '重新检测' : '检测',
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: _busy || _selected == line.url
                            ? null
                            : () => _select(line.url),
                        child: Text(_selected == line.url ? '已选择' : '使用此线路'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class _LineResult {
  const _LineResult(
    this.apiValid,
    this.httpStatus,
    this.elapsedMs,
    this.failure,
  );
  final bool apiValid;
  final int httpStatus, elapsedMs;
  final String failure;
  static const failures = {
    'dns': '域名解析失败',
    'timeout': '连接超时',
    'connection': '连接中断',
    'verification': '站点要求浏览器验证',
    'backoff': '站点暂时限制请求',
    'http': '站点返回错误状态',
    'cancelled': '检测已取消',
    'invalid_data': '没有取得有效目录数据',
  };
  factory _LineResult.fromJson(Map<String, dynamic> data) => _LineResult(
    data['apiValid'] == true,
    data['httpStatus'] as int? ?? 0,
    data['elapsedMs'] as int? ?? 0,
    data['apiValid'] == true
        ? ''
        : failures.containsKey(data['failure'])
        ? data['failure'] as String
        : 'other',
  );
  String get label => apiValid
      ? '目录接口通过 · $elapsedMs ms'
      : '${failures[failure] ?? '检测未通过'}${httpStatus > 0 ? ' · HTTP $httpStatus' : ''}';
  Map<String, dynamic> toJson() => {
    'apiValid': apiValid,
    'httpStatus': httpStatus,
    'elapsedMs': elapsedMs,
    'failure': failure,
    'mediaChecked': false,
  };
}
