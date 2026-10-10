import 'models.dart';

/// A closed schema: no query, drama ID, URL, header or exception text is kept.
class SourceDiagnostic {
  const SourceDiagnostic({
    required this.source,
    required this.method,
    required this.at,
    required this.elapsedMs,
    this.page = 1,
    this.refresh = false,
    this.background = false,
    this.networkAttempts,
    this.cacheHits = 0,
    this.sharedWaits = 0,
    this.httpStatus = 0,
    this.result = 'success',
    this.failure = '',
    this.stage = 'unknown',
  });
  static const methods = {
    'catalog',
    'categories',
    'ranking',
    'boards',
    'recommendations',
    'search',
    'suggestions',
    'detail',
    'chapters',
  };
  static const results = {'success', 'partial', 'failed', 'cancelled'};
  static const failures = {
    '',
    'cancelled',
    'verification',
    'dns',
    'timeout',
    'backoff',
    'http',
    'connection',
    'other',
  };
  static const stages = {
    'unknown',
    'complete',
    'request',
    'response',
    'cache',
    'shared',
    'cancelled',
    'verification',
    'dns',
    'timeout',
    'backoff',
    'http',
    'connection',
  };
  final DramaSource source;
  final String method, result, failure, stage;
  final DateTime at;
  final int elapsedMs, page, cacheHits, sharedWaits, httpStatus;
  final int? networkAttempts;
  final bool refresh, background;

  factory SourceDiagnostic.fromJson(Map value) {
    int number(String key, {int fallback = 0, int maximum = 1000000}) {
      final raw = value[key] ?? fallback;
      if (raw is! int || raw < 0 || raw > maximum) {
        throw const FormatException('诊断数据无效');
      }
      return raw;
    }

    if (!methods.contains(value['method']) ||
        !results.contains(value['result']) ||
        !failures.contains(value['failure']) ||
        !stages.contains(value['stage'])) {
      throw const FormatException('诊断数据无效');
    }
    return SourceDiagnostic(
      source: DramaSource.parse(value['source']),
      method: value['method'] as String,
      at: DateTime.parse(value['at'] as String),
      elapsedMs: number('elapsedMs'),
      page: number('page', fallback: 1),
      refresh: value['refresh'] == true,
      background: value['background'] == true,
      networkAttempts: value['networkAttempts'] == null
          ? null
          : number('networkAttempts'),
      cacheHits: number('cacheHits'),
      sharedWaits: number('sharedWaits'),
      httpStatus: number('httpStatus', maximum: 599),
      result: value['result'] as String,
      failure: value['failure'] as String,
      stage: value['stage'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'source': source.name,
    'method': method,
    'at': at.toUtc().toIso8601String(),
    'elapsedMs': elapsedMs,
    'page': page,
    'refresh': refresh,
    'background': background,
    'networkAttempts': networkAttempts,
    'cacheHits': cacheHits,
    'sharedWaits': sharedWaits,
    'httpStatus': httpStatus,
    'result': result,
    'failure': failure,
    'stage': stage,
  };

  String get methodLabel => switch (method) {
    'catalog' => '目录',
    'categories' => '分类',
    'ranking' => '栏目内容',
    'boards' => '栏目列表',
    'recommendations' => '推荐',
    'search' => '搜索',
    'suggestions' => '搜索联想',
    'detail' => '详情',
    _ => '分集',
  };
  String get resultLabel => switch (result) {
    'success' => '成功',
    'partial' => '部分结果 / 缓存回退',
    'cancelled' => '已取消',
    _ => '失败',
  };
  String get failureLabel => switch (failure) {
    'dns' => '域名解析异常',
    'verification' => '站点要求浏览器验证',
    'timeout' => '连接超时',
    'backoff' => '站点限制请求，稍后重试',
    'http' => '站点返回错误状态',
    'connection' => '网络连接中断',
    'cancelled' => '操作已取消',
    'other' => switch (stage) {
      'response' => '返回内容无法处理',
      _ => '请求未完成',
    },
    _ => '',
  };
}
