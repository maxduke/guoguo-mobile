import 'models.dart';
import 'series_title.dart';

enum CatalogSort {
  recommended('默认顺序'),
  title('剧名'),
  newest('最新上线'),
  heat('热度');

  const CatalogSort(this.label);
  final String label;
}

String searchText(String value) {
  final fullWidth = String.fromCharCodes(
    value.runes.map(
      (r) => r >= 0xff01 && r <= 0xff5e
          ? r - 0xfee0
          : r == 0x3000
          ? 32
          : r,
    ),
  );
  final normalized = fullWidth
      .toLowerCase()
      .replaceAllMapped(
        RegExp(r'第([零〇一二两三四五六七八九十百\d]+)季'),
        (m) => '第${_seasonNumber(m[1]!)}季',
      )
      .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
  return normalized.isEmpty ? fullWidth.trim().toLowerCase() : normalized;
}

int _seasonNumber(String value) {
  final number = int.tryParse(value);
  if (number != null) return number;
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var total = 0, current = 0;
  for (final rune in value.split('')) {
    if (rune == '十' || rune == '百') {
      total += (current == 0 ? 1 : current) * (rune == '十' ? 10 : 100);
      current = 0;
    } else {
      current = digits[rune] ?? 0;
    }
  }
  return total + current;
}

List<String> _searchWords(String query) => query
    .trim()
    .split(RegExp(r'\s+'))
    .map(searchText)
    .where((word) => word.isNotEmpty)
    .toList();

bool _matchesWords(Drama drama, List<String> words) {
  if (words.isEmpty) return true;
  final title = searchText(drama.title);
  return words.every(title.contains);
}

bool matchesDrama(Drama drama, String query) =>
    _matchesWords(drama, _searchWords(query));

List<(String, int?)> _titleParts(String title) => RegExp(r'\d+|\D+')
    .allMatches(searchText(title))
    .map((match) => (match[0]!, int.tryParse(match[0]!)))
    .toList();

int _compareTitleParts(List<(String, int?)> a, List<(String, int?)> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    final x = a[i].$2, y = b[i].$2;
    final order = x != null && y != null
        ? x.compareTo(y)
        : a[i].$1.compareTo(b[i].$1);
    if (order != 0) return order;
  }
  return a.length.compareTo(b.length);
}

int naturalTitleCompare(String left, String right) =>
    _compareTitleParts(_titleParts(left), _titleParts(right));

double? heatValue(String text) {
  final match = RegExp(
    r'^(\d+(?:\.\d+)?)\s*([万亿千wkm]?)',
    caseSensitive: false,
  ).firstMatch(text.replaceAll(',', '').trim());
  if (match == null) return null;
  return double.parse(match[1]!) *
      switch (match[2]!.toLowerCase()) {
        '亿' => 100000000,
        '万' || 'w' => 10000,
        '千' || 'k' => 1000,
        'm' => 1000000,
        _ => 1,
      };
}

List<Drama> queryCatalog(
  Iterable<Drama> catalog, {
  String query = '',
  String category = '全部',
  bool hideVip = false,
  CatalogSort sort = CatalogSort.recommended,
}) {
  final words = _searchWords(query);
  final rows = catalog
      .where(
        (d) =>
            _matchesWords(d, words) &&
            (category == '全部' || d.category == category) &&
            (!hideVip || d.vip != true),
      )
      .toList();
  if (sort == CatalogSort.recommended) return rows;
  // Keys live for this sort only, so refreshed metadata cannot leave stale keys.
  final titles = <Drama, List<(String, int?)>>{};
  int compareTitle(Drama a, Drama b) => _compareTitleParts(
    titles.putIfAbsent(a, () => _titleParts(a.title)),
    titles.putIfAbsent(b, () => _titleParts(b.title)),
  );
  rows.sort((a, b) {
    var order = 0;
    switch (sort) {
      case CatalogSort.title:
        order = compareTitle(a, b);
      case CatalogSort.newest:
        final x = DateTime.tryParse(a.date), y = DateTime.tryParse(b.date);
        order = x == null
            ? (y == null ? 0 : 1)
            : y == null
            ? -1
            : y.compareTo(x);
      case CatalogSort.heat:
        final x = heatValue(a.heat), y = heatValue(b.heat);
        order = x == null
            ? (y == null ? 0 : 1)
            : y == null
            ? -1
            : y.compareTo(x);
      case CatalogSort.recommended:
        break;
    }
    return order != 0 ? order : compareTitle(a, b);
  });
  return rows;
}

List<Drama> relatedSeries(
  Drama current,
  Iterable<Drama> candidates, {
  int limit = 200,
}) {
  if (current.source == DramaSource.hongguo) {
    final anchor = SeriesTitle.parse(current.title);
    if (anchor == null) return [];
    final rows = candidates.where((d) => d.source == current.source).toList();
    final units = {
      for (final row in rows)
        if (SeriesTitle.parse(row.title) case final info?)
          if (info.key == anchor.key && info.unit != null) info.unit!,
    };
    final unit = anchor.unit ?? (units.length == 1 ? units.single : null);
    if (unit == null) return [];
    final related = {
      for (final row in rows)
        if (row.key != current.key)
          if (SeriesTitle.parse(row.title) case final info?)
            if (info.key == anchor.key &&
                (info.unit == null || info.unit == unit))
              row.key: row,
    }.values.toList();
    related.sort((a, b) {
      final order = SeriesTitle.parse(
        a.title,
      )!.season.compareTo(SeriesTitle.parse(b.title)!.season);
      return order != 0 ? order : naturalTitleCompare(a.title, b.title);
    });
    return related.take(limit).toList();
  }
  String base(String title) =>
      searchText(title).replaceFirst(RegExp(r'第[零〇一二两三四五六七八九十百\d]+[季部]$'), '');
  final title = base(current.title);
  if (title.isEmpty) return [];
  final rows = {
    for (final row in candidates)
      if (row.key != current.key &&
          row.source == current.source &&
          base(row.title) == title)
        row.key: row,
  }.values.toList();
  rows.sort((a, b) => naturalTitleCompare(a.title, b.title));
  return rows.take(100).toList();
}
