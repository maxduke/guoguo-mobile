import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;

class PreferencesStore extends ChangeNotifier {
  PreferencesStore({required Future<void> Function() save}) : _save = save;
  final Future<void> Function() _save;
  final _theme = ValueNotifier(ThemeMode.system);
  ValueListenable<ThemeMode> get theme => _theme;
  ThemeMode get themeMode => _theme.value;
  set themeMode(ThemeMode value) => _theme.value = value;

  bool cellularDownloads = false, cellularPrefetch = false, prefetch = true;

  bool autoAdvance = true;

  bool progressivePreparation = false;

  double playbackSpeed = 1;

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
    themeMode = ThemeMode.values.firstWhere(
      (v) => v.name == state['theme'],
      orElse: () => ThemeMode.system,
    );
    cellularDownloads = state['cellularDownloads'] == true;
    cellularPrefetch = state['cellularPrefetch'] == true;
    prefetch = state['prefetch'] != false;
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
    'autoAdvance': autoAdvance,
    'progressivePreparation': progressivePreparation,
    'playbackSpeed': playbackSpeed,
  };

  @override
  void dispose() {
    _theme.dispose();
    super.dispose();
  }
}
