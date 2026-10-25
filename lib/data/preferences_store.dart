import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;

import '../domain/models.dart';

class PreferencesStore extends ChangeNotifier {
  PreferencesStore({required Future<void> Function() save}) : _save = save;
  final Future<void> Function() _save;
  final _theme = ValueNotifier(ThemeMode.system);
  ValueListenable<ThemeMode> get theme => _theme;
  ThemeMode get themeMode => _theme.value;
  set themeMode(ThemeMode value) => _theme.value = value;

  bool cellularDownloads = false, cellularPrefetch = false, prefetch = true;
  bool catalogPrefetch = true;

  bool autoAdvance = true;

  bool progressivePreparation = false;

  double playbackSpeed = 1;

  final _favoriteSources = <DramaSource>{};
  final _hiddenSources = <DramaSource>{};
  final _enabledSources = <DramaSource>{};
  final _recentSources = <DramaSource>[];
  static const maxRecentSources = 6;
  Set<DramaSource> get favoriteSources => Set.unmodifiable(_favoriteSources);
  Set<DramaSource> get hiddenSources => Set.unmodifiable({
    ..._hiddenSources,
    for (final source in DramaSource.values)
      if (!source.enabledByDefault && !_enabledSources.contains(source)) source,
  });
  List<DramaSource> get recentSources => List.unmodifiable(_recentSources);

  void rememberSource(DramaSource source) {
    if (_recentSources.firstOrNull == source) return;
    _recentSources.remove(source);
    _recentSources.insert(0, source);
    if (_recentSources.length > maxRecentSources) _recentSources.removeLast();
    notifyListeners();
  }

  Future<void> saveSources() => _save();

  Future<void> toggleFavoriteSource(DramaSource source) async {
    if (!_favoriteSources.remove(source)) _favoriteSources.add(source);
    notifyListeners();
    await _save();
  }

  Future<void> setSourceHidden(DramaSource source, bool hidden) async {
    if (hiddenSources.contains(source) == hidden) return;
    if (hidden) {
      _hiddenSources.add(source);
      _enabledSources.remove(source);
    } else {
      _hiddenSources.remove(source);
      if (!source.enabledByDefault) _enabledSources.add(source);
    }
    notifyListeners();
    await _save();
  }

  Future<void> setTheme(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await _save();
  }

  Future<void> setNetwork({bool? downloads, bool? preload}) async {
    cellularDownloads = downloads ?? cellularDownloads;
    cellularPrefetch = preload ?? cellularPrefetch;
    notifyListeners();
    await _save();
  }

  Future<void> setPrefetch(bool enabled) async {
    prefetch = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setCatalogPrefetch(bool enabled) async {
    catalogPrefetch = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setPlayback({
    bool? advance,
    double? speed,
    bool? progressive,
  }) async {
    if (speed != null && !const [.75, 1, 1.25, 1.5, 2].contains(speed)) {
      throw ArgumentError.value(speed, 'speed');
    }
    autoAdvance = advance ?? autoAdvance;
    progressivePreparation = progressive ?? progressivePreparation;
    playbackSpeed = speed ?? playbackSpeed;
    notifyListeners();
    await _save();
  }

  void restore(Map<String, dynamic> state) {
    List<DramaSource> sources(String key) {
      final rows = state[key] as List? ?? [];
      if (rows.length > DramaSource.values.length) {
        throw const FormatException('站源偏好格式不正确');
      }
      return rows.map(DramaSource.parse).toSet().toList();
    }

    final favorites = sources('favoriteSources');
    final hidden = sources('hiddenSources');
    final enabled = sources('enabledSources');
    final recent = sources('recentSources').take(maxRecentSources).toList();
    _favoriteSources
      ..clear()
      ..addAll(favorites);
    _hiddenSources
      ..clear()
      ..addAll(hidden);
    _enabledSources
      ..clear()
      ..addAll(enabled);
    _recentSources
      ..clear()
      ..addAll(recent);
    themeMode = ThemeMode.values.firstWhere(
      (v) => v.name == state['theme'],
      orElse: () => ThemeMode.system,
    );
    cellularDownloads = state['cellularDownloads'] == true;
    cellularPrefetch = state['cellularPrefetch'] == true;
    prefetch = state['prefetch'] != false;
    catalogPrefetch = state['catalogPrefetch'] != false;
    autoAdvance = state['autoAdvance'] != false;
    progressivePreparation = state['progressivePreparation'] == true;
    final speed = state['playbackSpeed'];
    if (speed is num && const [.75, 1, 1.25, 1.5, 2].contains(speed)) {
      playbackSpeed = speed.toDouble();
    }
    notifyListeners();
  }

  Map<String, dynamic> toJson() => {
    'theme': themeMode.name,
    'cellularDownloads': cellularDownloads,
    'cellularPrefetch': cellularPrefetch,
    'prefetch': prefetch,
    'catalogPrefetch': catalogPrefetch,
    'autoAdvance': autoAdvance,
    'progressivePreparation': progressivePreparation,
    'playbackSpeed': playbackSpeed,
    'favoriteSources': _favoriteSources.map((source) => source.name).toList(),
    'hiddenSources': _hiddenSources.map((source) => source.name).toList(),
    'enabledSources': _enabledSources.map((source) => source.name).toList(),
    'recentSources': _recentSources.map((source) => source.name).toList(),
  };

  @override
  void dispose() {
    _theme.dispose();
    super.dispose();
  }
}
