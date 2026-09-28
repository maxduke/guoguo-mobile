enum DramaSource {
  hongguo('红果', '真人 · 漫剧 · AI 剧'),
  huangguo('黄果', '发现更多好故事'),
  huangdou('黄豆', '短剧，也有新滋味'),
  huangju('剧果', '发现新的故事'),
  yeguo('野果', '更多短剧随心看'),
  dsd('帝果', '精彩故事继续看'),
  yaguo('芽果', '发现新的故事'),
  maoguo('猫果', '短剧随心搜'),
  fanguo('饭果', '发现更多好故事'),
  guanguo('观果', '精彩故事继续看'),
  heguo('河果', '短剧随心搜'),
  xingguo('星果', '发现新的故事'),
  huaguo('花果', '更多短剧随心看'),
  niuguo('牛果', '发现更多好故事'),
  wangguo('网果', '精彩故事继续看'),
  faguo('发果', '更多短剧随心看'),
  piguo('皮果', '发现新的故事'),
  wuguo('伍果', '精彩故事继续看');

  const DramaSource(this.label, this.subtitle);
  final String label;
  final String subtitle;
  bool get remoteCategories => switch (this) {
    hongguo || huangguo || huangdou => false,
    _ => true,
  };
  bool get onlineSearch => this == hongguo || remoteCategories;
  bool get rankings => !remoteCategories;
  static DramaSource parse(Object? value) => values.firstWhere(
    (source) => source.name == value,
    orElse: () => throw const FormatException('未知站源'),
  );
}

class Drama {
  const Drama({
    required this.id,
    required this.source,
    required this.title,
    this.description = '',
    this.cover = '',
    this.category = '',
    this.episodes = 0,
    this.heat = '',
    this.date = '',
    this.status = '',
    this.vip,
    this.tags = const [],
  });
  final String id, title, description, cover, category;
  final DramaSource source;
  final int episodes;
  final String heat, date, status;
  final bool? vip;
  final List<String> tags;
  String get statusLabel => switch (status) {
    'finished' || 'completed' => '已完结',
    'ongoing' => '连载中',
    _ => '',
  };
  String get key => '${source.name}:$id';
  factory Drama.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final title = json['title'] as String;
    if (id.isEmpty || title.isEmpty) throw const FormatException('短剧资料不完整');
    return Drama(
      id: id,
      source: DramaSource.parse(json['source']),
      title: title,
      description: json['description'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      category: json['category'] as String? ?? '',
      episodes: (json['episodes'] as num?)?.toInt() ?? 0,
      heat: '${json['heat'] ?? ''}',
      date: json['date'] as String? ?? '',
      status: json['status'] as String? ?? '',
      vip: json['vip'] as bool?,
      tags: (json['tags'] as List? ?? []).cast<String>(),
    );
  }
  Drama merge(Drama patch, {bool replaceTags = false}) {
    if (patch.key != key) throw const FormatException('剧集资料不匹配');
    return Drama(
      id: id,
      source: source,
      title: patch.title.isEmpty || patch.title == id ? title : patch.title,
      description: patch.description.isEmpty ? description : patch.description,
      cover: patch.cover.isEmpty ? cover : patch.cover,
      category: patch.category.isEmpty || patch.category == '未分类'
          ? category
          : patch.category,
      episodes: patch.episodes > 0 ? patch.episodes : episodes,
      heat: patch.heat.isEmpty ? heat : patch.heat,
      date: patch.date.isEmpty ? date : patch.date,
      status: patch.status.isEmpty ? status : patch.status,
      vip: patch.vip ?? vip,
      tags: replaceTags || patch.tags.isNotEmpty ? patch.tags : tags,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source.name,
    'title': title,
    'description': description,
    'cover': cover,
    'category': category,
    'episodes': episodes,
    'heat': heat,
    'date': date,
    'status': status,
    'vip': vip,
    'tags': tags,
  };
}

class Episode {
  const Episode({
    required this.id,
    required this.title,
    required this.number,
    required this.raw,
  });
  final String id, title;
  final int number;
  final Map<String, dynamic> raw;
  bool get vip => raw['vip'] == true;
  factory Episode.fromJson(Map<String, dynamic> json, int index) => Episode(
    id: json['id'] as String,
    title: json['title'] as String? ?? '第 ${index + 1} 集',
    number: int.tryParse('${json['currentEpisode']}') ?? index + 1,
    raw: json,
  );
}

class WatchRecord {
  const WatchRecord({
    required this.drama,
    required this.episodeId,
    required this.episodeIndex,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });
  final Drama drama;
  final String episodeId;
  final int episodeIndex, positionMs, durationMs;
  final DateTime updatedAt;
  double get progress =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0, 1);
  factory WatchRecord.fromJson(Map<String, dynamic> json) {
    final index = json['episodeIndex'] as int;
    final position = json['positionMs'] as int;
    final duration = json['durationMs'] as int;
    if (index < 0 || position < 0 || duration < 0) {
      throw const FormatException('观看记录无效');
    }
    return WatchRecord(
      drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
      episodeId: json['episodeId'] as String,
      episodeIndex: index,
      positionMs: position,
      durationMs: duration,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
    'drama': drama.toJson(),
    'episodeId': episodeId,
    'episodeIndex': episodeIndex,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

class ResolvedMedia {
  ResolvedMedia.fromJson(Map<String, dynamic> json)
    : url = json['url'] as String,
      remoteUrl = json['remoteUrl'] as String,
      expiresAt = json['expiresAt'] as int? ?? 0,
      session = json['session'] as String? ?? '',
      contentKey = json['contentKey'] as String? ?? '',
      headers = Map<String, String>.from(json['headers'] as Map? ?? {}),
      qualities = (json['qualities'] as List? ?? []).cast<int>(),
      quality = json['quality'] as int? ?? 0,
      routeIndex = json['routeIndex'] as int? ?? 0,
      routeCount = json['routeCount'] as int? ?? 1,
      hls = json['hls'] == true,
      castDirect = json['castDirect'] == true;
  final String url, remoteUrl, session, contentKey;
  final Map<String, String> headers;
  final List<int> qualities;
  final int quality, routeIndex, routeCount, expiresAt;
  bool freshAt(DateTime now) =>
      expiresAt == 0 || now.millisecondsSinceEpoch + 5000 < expiresAt;
  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;
  final bool hls, castDirect;
}

class RecordBackup {
  RecordBackup(this.favorites, this.history);
  final List<Drama> favorites;
  final List<WatchRecord> history;
  factory RecordBackup.fromJson(Map<String, dynamic> json) {
    if (json['format'] != 'guoguo.records' || json['version'] != 1) {
      throw const FormatException('不支持的备份格式或版本');
    }
    final favorites = json['favorites'] as List;
    final history = json['history'] as List;
    if (favorites.length > 100000 || history.length > 100000) {
      throw const FormatException('备份记录过多');
    }
    return RecordBackup(
      favorites
          .map((v) => Drama.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList(),
      history
          .map((v) => WatchRecord.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList(),
    );
  }
  Map<String, dynamic> toJson() => {
    'format': 'guoguo.records',
    'version': 1,
    'favorites': favorites.map((v) => v.toJson()).toList(),
    'history': history.map((v) => v.toJson()).toList(),
  };
}
