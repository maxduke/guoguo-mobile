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
    String? requestResult,
    this.validation = 'not_checked',
    this.sourceStage = '',
    this.sourceFailure = '',
    this.responseBytes = 0,
  }) : requestResult = requestResult ?? result;
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
    'cover',
    'resolve',
    'downloadPlan',
  };
  static const results = {'success', 'partial', 'failed', 'cancelled'};
  static const requestResults = {...results, 'not_requested'};
  static const validations = {'not_checked', 'passed', 'failed'};
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
    'image_decode',
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
  static const sourceStages = {
    '',
    'registration',
    'model',
    'model_fallback',
    'plugin_script',
  };
  static const sourceFailures = {
    '',
    'registration_failed',
    'http_denied',
    'rate_limited',
    'http_error',
    'empty_model',
    'invalid_model',
    'invalid_response',
    'business_rejected',
    'fallback_invalid',
    'fallback_request_failed',
  };
  final String sourceStage, sourceFailure;
  final int responseBytes;
  final DramaSource source;
  final String method, result, failure, stage, requestResult, validation;
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
        !requestResults.contains(value['requestResult'] ?? value['result']) ||
        !validations.contains(value['validation'] ?? 'not_checked') ||
        !failures.contains(value['failure']) ||
        !stages.contains(value['stage']) ||
        !sourceStages.contains(value['sourceStage'] ?? '') ||
        !sourceFailures.contains(value['sourceFailure'] ?? '')) {
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
      requestResult: value['requestResult'] as String?,
      validation: value['validation'] as String? ?? 'not_checked',
      sourceStage: value['sourceStage'] as String? ?? '',
      sourceFailure: value['sourceFailure'] as String? ?? '',
      responseBytes: number('responseBytes', maximum: 32 * 1024 * 1024),
    );
  }

  SourceDiagnostic withValidation({
    required bool valid,
    String? failureStage,
  }) => SourceDiagnostic(
    source: source,
    method: method,
    at: at,
    elapsedMs: elapsedMs,
    page: page,
    refresh: refresh,
    background: background,
    networkAttempts: networkAttempts,
    cacheHits: cacheHits,
    sharedWaits: sharedWaits,
    httpStatus: httpStatus,
    sourceStage: sourceStage,
    sourceFailure: sourceFailure,
    responseBytes: responseBytes,
    requestResult: requestResult,
    validation: valid ? 'passed' : 'failed',
    result: valid ? result : 'failed',
    failure: valid ? failure : 'other',
    stage: valid ? stage : failureStage ?? 'response',
  );

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
    'requestResult': requestResult,
    'validation': validation,
    if (sourceStage.isNotEmpty) 'sourceStage': sourceStage,
    if (sourceFailure.isNotEmpty) 'sourceFailure': sourceFailure,
    if (sourceStage.isNotEmpty) 'responseBytes': responseBytes,
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
    'cover' => '封面',
    'resolve' => '播放取源',
    'downloadPlan' => '下载取源',
    _ => '分集',
  };
  String get sourceStageLabel => switch (sourceStage) {
    'registration' => '准备播放连接',
    'model' => '读取播放资料',
    'model_fallback' => '读取备用播放资料',
    'plugin_script' => '加载插件脚本',
    _ => '',
  };
  String get sourceFailureLabel => switch (sourceFailure) {
    'registration_failed' => '播放连接未就绪，请稍后重试',
    'http_denied' => '站源拒绝取源',
    'rate_limited' => '站源限制取源，请稍后重试',
    'empty_model' => '站源未返回播放资料',
    'business_rejected' => '站源暂未提供本集资源',
    'fallback_request_failed' => '备用播放资料读取失败',
    'http_error' => '取源接口返回错误',
    'invalid_model' ||
    'invalid_response' ||
    'fallback_invalid' => '播放资料不完整或校验未通过',
    _ => '',
  };
  String get resultLabel => _resultLabel(result);
  String get requestResultLabel => _resultLabel(requestResult);
  String get validationLabel => switch (validation) {
    'passed' => '内容校验通过',
    'failed' => '内容校验失败',
    _ => '未进行内容校验',
  };

  static String _resultLabel(String result) => switch (result) {
    'not_requested' => '未调用核心',
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
      'image_decode' => '封面图片无法解码',
      'response' => '返回内容无法处理',
      _ => '请求未完成',
    },
    _ => '',
  };
}
