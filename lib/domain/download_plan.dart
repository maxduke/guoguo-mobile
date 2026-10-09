import 'dart:convert';
import 'dart:typed_data';

String _fileName(Object? value) {
  final name = value as String;
  if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(name) ||
      name == '.' ||
      name == '..') {
    throw const FormatException('无效的资源文件名');
  }
  return name;
}

class DownloadAsset {
  const DownloadAsset._(this.name, this.url, this.identity);
  final String name, url, identity;

  factory DownloadAsset.fromJson(Map value) {
    final url = value['url'] as String;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const FormatException('无效的资源地址');
    }
    return DownloadAsset._(
      _fileName(value['name']),
      url,
      value['identity'] as String? ?? url,
    );
  }
}

class InlineDownloadAsset {
  const InlineDownloadAsset._(this.name, this.bytes);
  final String name;
  final Uint8List bytes;

  factory InlineDownloadAsset.fromJson(Map value) => InlineDownloadAsset._(
    _fileName(value['name']),
    base64Decode(value['body'] as String).asUnmodifiableView(),
  );
}

class DownloadPlan {
  const DownloadPlan._({
    required this.input,
    required this.assets,
    required this.inline,
    required this.headers,
    required this.contentKey,
    required this.process,
    required this.refreshOnResume,
  });
  final String input, contentKey;
  final List<DownloadAsset> assets;
  final List<InlineDownloadAsset> inline;
  final Map<String, String> headers;
  final bool process, refreshOnResume;

  factory DownloadPlan.fromJson(Map value) {
    final input = _fileName(value['input']);
    final assets = List<DownloadAsset>.unmodifiable(
      (value['assets'] as List).map(
        (raw) => DownloadAsset.fromJson(raw as Map),
      ),
    );
    final inline = List<InlineDownloadAsset>.unmodifiable(
      (value['inline'] as List).map(
        (raw) => InlineDownloadAsset.fromJson(raw as Map),
      ),
    );
    final names = <String>{};
    for (final name in [
      ...assets.map((asset) => asset.name),
      ...inline.map((asset) => asset.name),
    ]) {
      if (!names.add(name)) throw const FormatException('资源文件名重复');
    }
    if (!names.contains(input)) throw const FormatException('缺少下载输入文件');
    return DownloadPlan._(
      input: input,
      assets: assets,
      inline: inline,
      headers: Map.unmodifiable(
        Map<String, String>.from(value['headers'] as Map),
      ),
      contentKey: value['contentKey'] as String? ?? '',
      process: value['process'] as bool? ?? false,
      refreshOnResume: value['refreshOnResume'] as bool? ?? false,
    );
  }
}
