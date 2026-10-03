class SeriesTitle {
  const SeriesTitle(this.baseTitle, this.key, this.season, this.unit);
  final String baseTitle, key;
  final int season;
  final String? unit;

  static String normalize(String title) => _width(
    title,
  ).toLowerCase().replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');

  static String _width(String title) => String.fromCharCodes(
    title.runes.map(
      (r) => r >= 0xff01 && r <= 0xff5e
          ? r - 0xfee0
          : r == 0x3000
          ? 32
          : r,
    ),
  );

  static SeriesTitle? parse(String title) {
    title = _width(title).trim();
    if (normalize(title).isEmpty) return null;
    final suffix = RegExp(
      r'第\s*([\d零〇一二两兩三四五六七八九十百]+)\s*([季部])[\s\p{P}\p{S}]*$',
      unicode: true,
    ).firstMatch(title);
    if (suffix == null) return SeriesTitle(title, normalize(title), 1, null);
    final base = title.substring(0, suffix.start).trim();
    final number = _number(suffix[1]!);
    if (normalize(base).isEmpty || number == null) return null;
    return SeriesTitle(base, normalize(base), number, suffix[2]);
  }

  static int? _number(String label) {
    var value = int.tryParse(label);
    if (value == null) {
      const digits = {
        '零': 0,
        '〇': 0,
        '一': 1,
        '二': 2,
        '两': 2,
        '兩': 2,
        '三': 3,
        '四': 4,
        '五': 5,
        '六': 6,
        '七': 7,
        '八': 8,
        '九': 9,
      };
      var current = 0, total = 0, previousUnit = 1000;
      for (final character in label.split('')) {
        final digit = digits[character];
        if (digit != null) {
          current = current * 10 + digit;
        } else {
          if (character != '百' && character != '十') return null;
          final unit = character == '百' ? 100 : 10;
          if (unit >= previousUnit || current > 9) return null;
          total += (current == 0 ? 1 : current) * unit;
          current = 0;
          previousUnit = unit;
        }
      }
      value = total + current;
    }
    return value >= 1 && value <= 200 ? value : null;
  }
}
