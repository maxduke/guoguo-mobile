/// Keep format-specific demuxer options off other inputs (notably CENC MP4).
List<String> remuxArguments({
  required String input,
  required String output,
  String contentKey = '',
  Map<String, String> headers = const {},
  bool hls = false,
}) => [
  '-hide_banner',
  '-loglevel',
  'error',
  '-nostdin',
  '-y',
  if (input.startsWith('http')) ...[
    '-rw_timeout',
    '20000000',
    if (headers.isNotEmpty) ...[
      '-headers',
      headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join(),
    ],
  ],
  if (contentKey.isNotEmpty) ...['-decryption_key', contentKey],
  if (hls) ...[
    '-allowed_extensions', 'ALL',
    // Only our on-device download manifests use opaque .bin resource names.
    if (!input.startsWith('http')) ...[
      '-allowed_segment_extensions',
      'ALL',
      '-extension_picky',
      '0',
    ],
  ],
  '-protocol_whitelist',
  'file,http,https,tcp,tls,crypto,data',
  '-i',
  input,
  '-map',
  '0:v:0',
  '-map',
  '0:a:0?',
  '-c',
  'copy',
  '-movflags',
  '+faststart',
  output,
];

/// Classify native failures without exposing signed URLs, headers or keys.
String mediaFailureMessage(String log, int? code) {
  final text = log.toLowerCase();
  if (text.contains('no space left')) return '存储空间不足，请清理空间后重试';
  if (text.contains('403') || text.contains('401')) {
    return '视频链接已失效或访问被拒绝，请重试以重新获取链接';
  }
  if (text.contains('timed out') ||
      text.contains('connection') ||
      text.contains('resolve hostname') ||
      text.contains('network')) {
    return '视频传输失败，请检查网络后重试';
  }
  if (text.contains('option') &&
      (text.contains('not found') || text.contains('unrecognized'))) {
    return '视频处理组件不兼容（参数错误），请更新应用';
  }
  return '视频处理失败（错误码 ${code ?? "未知"}），请重试或切换清晰度';
}
