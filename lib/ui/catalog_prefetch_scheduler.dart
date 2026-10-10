import 'dart:async';

/// At most one extra page per settling period, with one request in flight.
class CatalogPrefetchScheduler {
  CatalogPrefetchScheduler({required this.onIdle});
  final void Function() onIdle;
  Timer? _timer;
  bool _used = false, _closed = false;

  void scrolled() {
    if (_closed) return;
    _used = false;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 350), settle);
  }

  void settle() {
    _timer?.cancel();
    _timer = null;
    if (_closed || _used) return;
    _used = true;
    onIdle();
  }

  void layout() {
    if (_closed || _used || _timer != null) return;
    _timer = Timer(const Duration(milliseconds: 350), settle);
  }

  void reset() {
    _timer?.cancel();
    _timer = null;
    _used = false;
  }

  void dispose() {
    _closed = true;
    reset();
  }
}
