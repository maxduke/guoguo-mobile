import 'series_title.dart';

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
  piguo('皮果', '发现新的故事'),
  wuguo('伍果', '精彩故事继续看');

  const DramaSource(this.label, this.subtitle);
  final String label;
  final String subtitle;
  bool get remoteCategories => switch (this) {
    hongguo || huangguo || huangdou => false,
    _ => true,
  };
  bool get onlineSearch =>
      this == hongguo || this == huangguo || remoteCategories;
  bool get rankings => true;
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
  bool hasSameMetadata(Drama other) =>
      identical(this, other) ||
      (id == other.id &&
          source == other.source &&
          title == other.title &&
          description == other.description &&
          cover == other.cover &&
          category == other.category &&
          episodes == other.episodes &&
          heat == other.heat &&
          date == other.date &&
          status == other.status &&
          vip == other.vip &&
          tags.length == other.tags.length &&
          tags.indexed.every((tag) => tag.$2 == other.tags[tag.$1]));

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
      tags: List<String>.unmodifiable(json['tags'] as List? ?? []),
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
    raw: Map.unmodifiable(json),
  );
}

class WatchRecord {
  const WatchRecord({
    required this.drama,
    required this.episodeId,
    required this.episodeIndex,
    this.episodeNumber,
    this.episodeCompleted = false,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });
  final Drama drama;
  final String episodeId;
  final int episodeIndex, positionMs, durationMs;
  // Queue position is not a source's display number (downloads may be sparse).
  final int? episodeNumber;
  // Only a confirmed playback end marks completion; position alone cannot.
  final bool episodeCompleted;
  final DateTime updatedAt;
  double get progress =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0, 1);
  factory WatchRecord.fromJson(Map<String, dynamic> json) {
    final index = json['episodeIndex'] as int;
    final number = json['episodeNumber'] as int?;
    final position = json['positionMs'] as int;
    final duration = json['durationMs'] as int;
    if (index < 0 ||
        (number != null && number < 0) ||
        position < 0 ||
        duration < 0) {
      throw const FormatException('观看记录无效');
    }
    return WatchRecord(
      drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
      episodeId: json['episodeId'] as String,
      episodeIndex: index,
      episodeNumber: number,
      episodeCompleted: json['episodeCompleted'] as bool? ?? false,
      positionMs: position,
      durationMs: duration,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
    'drama': drama.toJson(),
    'episodeId': episodeId,
    'episodeIndex': episodeIndex,
    if (episodeNumber != null) 'episodeNumber': episodeNumber,
    'episodeCompleted': episodeCompleted,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  WatchRecord withDrama(Drama updated) => WatchRecord(
    drama: updated,
    episodeId: episodeId,
    episodeIndex: episodeIndex,
    episodeNumber: episodeNumber,
    episodeCompleted: episodeCompleted,
    positionMs: positionMs,
    durationMs: durationMs,
    updatedAt: updatedAt,
  );
}

class ResolvedMedia {
  ResolvedMedia.fromJson(Map<String, dynamic> json)
    : url = json['url'] as String,
      remoteUrl = json['remoteUrl'] as String,
      expiresAt = json['expiresAt'] as int? ?? 0,
      prefetchedBytes = json['prefetchedBytes'] as int? ?? 0,
      prefetchMs = json['prefetchMs'] as int? ?? 0,
      session = json['session'] as String? ?? '',
      contentKey = json['contentKey'] as String? ?? '',
      headers = Map.unmodifiable(
        Map<String, String>.from(json['headers'] as Map? ?? {}),
      ),
      qualities = List<int>.unmodifiable(json['qualities'] as List? ?? []),
      quality = json['quality'] as int? ?? 0,
      routeIndex = json['routeIndex'] as int? ?? 0,
      routeCount = json['routeCount'] as int? ?? 1,
      hls = json['hls'] == true,
      castDirect = json['castDirect'] == true;
  final String url, remoteUrl, session, contentKey;
  final Map<String, String> headers;
  final List<int> qualities;
  final int quality, routeIndex, routeCount, expiresAt;
  final int prefetchedBytes, prefetchMs;
  bool freshAt(DateTime now) =>
      expiresAt == 0 || now.millisecondsSinceEpoch + 5000 < expiresAt;
  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;
  final bool hls, castDirect;
}

class SeasonNotice {
  const SeasonNotice(this.drama, {this.read = false});
  final Drama drama;
  final bool read;
  Map<String, dynamic> toJson() => {'drama': drama.toJson(), 'read': read};
}

class SeasonReminder {
  SeasonReminder({
    required this.anchor,
    required this.updatedAt,
    DateTime? enabledAt,
    this.initialized = false,
    Map<String, SeasonNotice> seasons = const {},
  }) : enabledAt = enabledAt ?? updatedAt,
       seasons = Map.unmodifiable(seasons);
  final Drama anchor;
  final DateTime updatedAt;
  final DateTime enabledAt;
  final bool initialized;
  final Map<String, SeasonNotice> seasons;
  int get unreadCount => seasons.values.where((n) => !n.read).length;
  Map<String, dynamic> toJson() => {
    'anchor': anchor.toJson(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'enabledAt': enabledAt.toUtc().toIso8601String(),
    'initialized': initialized,
    'seasons': {for (final n in seasons.entries) n.key: n.value.toJson()},
  };
  factory SeasonReminder.fromJson(Map<String, dynamic> json) {
    final anchor = Drama.fromJson(
      Map<String, dynamic>.from(json['anchor'] as Map),
    );
    final info = SeriesTitle.parse(anchor.title);
    final initialized = json['initialized'];
    final raw = json['seasons'];
    if (anchor.source != DramaSource.hongguo ||
        info == null ||
        initialized is! bool ||
        raw is! Map ||
        raw.length > 200) {
      throw const FormatException('新季提醒无效');
    }
    final seasons = <String, SeasonNotice>{};
    String? unit = info.unit;
    for (final entry in raw.entries) {
      final row = Map<String, dynamic>.from(entry.value as Map);
      final drama = Drama.fromJson(
        Map<String, dynamic>.from(row['drama'] as Map),
      );
      final season = SeriesTitle.parse(drama.title);
      final read = row['read'];
      if (entry.key != drama.key ||
          drama.source != anchor.source ||
          season == null ||
          season.key != info.key ||
          season.unit == null ||
          season.season <= info.season ||
          read is! bool ||
          (!initialized && !read) ||
          (unit != null && unit != season.unit)) {
        throw const FormatException('新季提醒无效');
      }
      unit = season.unit;
      seasons[drama.key] = SeasonNotice(drama, read: read);
    }
    final updatedAt = DateTime.parse(json['updatedAt'] as String);
    final enabledAt = DateTime.parse(json['enabledAt'] as String);
    if (enabledAt.isAfter(updatedAt)) throw const FormatException('新季提醒时间无效');
    return SeasonReminder(
      anchor: anchor,
      seasons: seasons,
      initialized: initialized,
      updatedAt: updatedAt,
      enabledAt: enabledAt,
    );
  }
}

class RecordBackup {
  static const maxRecords = 100000, maxSeasonReminders = 1000;
  RecordBackup(this.favorites, this.history, {this.seasonReminders = const []});
  final List<Drama> favorites;
  final List<WatchRecord> history;
  final List<SeasonReminder> seasonReminders;
  factory RecordBackup.fromJson(Map<String, dynamic> json) {
    if (json['format'] != 'guoguo.records' || json['version'] != 2) {
      throw const FormatException('不支持的备份格式或版本');
    }
    final favorites = json['favorites'] as List;
    final history = json['history'] as List;
    final reminders = json['seasonReminders'] as List;
    if (favorites.length > maxRecords ||
        history.length > maxRecords ||
        reminders.length > maxSeasonReminders) {
      throw const FormatException('备份记录过多');
    }
    final parsedReminders = reminders
        .map(
          (v) => SeasonReminder.fromJson(Map<String, dynamic>.from(v as Map)),
        )
        .toList();
    if (parsedReminders.map((r) => r.anchor.key).toSet().length !=
        parsedReminders.length) {
      throw const FormatException('新季提醒重复');
    }
    return RecordBackup(
      favorites
          .map((v) => Drama.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList(),
      history
          .map((v) => WatchRecord.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList(),
      seasonReminders: parsedReminders,
    );
  }
  Map<String, dynamic> toJson({List<Map<String, dynamic>>? historyRows}) => {
    'format': 'guoguo.records',
    'version': 2,
    'favorites': favorites.map((v) => v.toJson()).toList(),
    'history': historyRows ?? history.map((v) => v.toJson()).toList(),
    'seasonReminders': seasonReminders.map((v) => v.toJson()).toList(),
  };
}
