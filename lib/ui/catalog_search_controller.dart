import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/catalog_store.dart';
import '../domain/models.dart';

/// Owns the transient search session; caching and persistence stay in the store.
class CatalogSearchController extends ChangeNotifier {
  CatalogSearchController(this.catalog) : _source = catalog.source {
    input.addListener(_inputChanged);
    catalog.addListener(_sourceChanged);
  }

  final CatalogStore catalog;
  final input = TextEditingController();
  DramaSource _source;
  TextEditingValue _lastInput = TextEditingValue.empty;
  String _query = '';
  List<Drama>? _results;
  List<String> _suggestions = const [];
  String? _error, _notice;
  bool _loading = false, _hasMore = false, _closed = false;
  int _page = 0, _generation = 0;
  Timer? _suggestionTimer;
  ({DramaSource source, String query, String id})? _request;

  String get query => _query;
  List<Drama>? get results => _results;
  List<String> get suggestions => _suggestions;
  String? get error => _error;
  String? get notice => _notice;
  bool get loading => _loading;
  bool get hasMore => _hasMore;

  void _cancel() {
    _suggestionTimer?.cancel();
    final request = _request;
    _request = null;
    if (request != null) {
      unawaited(
        catalog.cancelSearch(request.source, request.query, request.id),
      );
    }
  }

  void _sourceChanged() {
    if (_source == catalog.source) return;
    _source = catalog.source;
    input.clear();
  }

  void _inputChanged() {
    final value = input.value;
    // Moving the caret does not change the query or invalidate loaded pages.
    if (value.text == _lastInput.text &&
        value.composing == _lastInput.composing) {
      return;
    }
    _lastInput = value;
    _cancel();
    final generation = ++_generation;
    _query = value.text.trim();
    _results = null;
    _page = 0;
    _hasMore = false;
    _suggestions = const [];
    _error = _notice = null;
    _loading = false;
    notifyListeners();
    if (_query.isEmpty ||
        _source != DramaSource.hongguo ||
        catalog.isOffline() ||
        !value.composing.isCollapsed) {
      return;
    }
    final query = _query;
    _suggestionTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final items = await catalog.suggestions(query);
        if (!_closed && generation == _generation) {
          _suggestions = List.unmodifiable(items);
          notifyListeners();
        }
      } catch (_) {
        // Explicit search remains available when suggestions fail.
      }
    });
  }

  Future<void> submit(String text) => _submit(text);

  Future<void> loadMore() => _submit(input.text, more: true);

  Future<void> retry() => _submit(input.text, more: _page > 0 && _hasMore);

  Future<void> _submit(String text, {bool more = false}) async {
    if (_closed || !input.value.composing.isCollapsed) return;
    final query = text.trim();
    if (query.isEmpty || (_loading && query == _query)) return;
    if (more && (!_hasMore || query != _query)) return;
    if (input.text != text) {
      input.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    _cancel();
    final generation = ++_generation;
    final source = catalog.source;
    final page = more ? _page + 1 : 1;
    // Every update for this page uses the same completed-page snapshot.
    final previous = more ? _results ?? const <Drama>[] : const <Drama>[];
    if (!more) {
      _page = 0;
      _hasMore = false;
    }
    bool current() =>
        !_closed && generation == _generation && source == catalog.source;
    final request = (
      source: source,
      query: query,
      id: 'home-$generation-${DateTime.now().microsecondsSinceEpoch}',
    );
    _query = query;
    _suggestions = const [];
    _error = _notice = null;
    _loading = source.onlineSearch && !catalog.isOffline();
    if (!_loading) {
      _results = null;
      _page = 0;
      _hasMore = false;
    }
    notifyListeners();
    if (!_loading) return;
    _request = request;
    try {
      final result = await catalog.searchCatalog(
        source,
        query,
        page: page,
        requestId: request.id,
        isActive: current,
        onPartial: (partial) {
          if (!current()) return;
          _results = _merge(previous, partial.items);
          _notice = '正在补全结果…';
          notifyListeners();
        },
      );
      if (!current()) return;
      _results = _merge(previous, result.items);
      _page = page;
      _hasMore = result.hasMore;
      _notice = result.warning.isNotEmpty
          ? result.warning
          : result.limited
          ? '已合并名称检索与官网结果；上游未提供完整分页，可用完整剧名继续查找。'
          : source == DramaSource.huangguo
          ? '在线检索范围：黄果 AI'
          : null;
    } catch (_) {
      if (current()) {
        if (more) _results = previous;
        _error = '搜索暂时失败，请检查网络后重试';
      }
    } finally {
      if (_request == request) _request = null;
      if (current()) {
        _loading = false;
        if (_error != null) _notice = null;
        notifyListeners();
      }
    }
  }

  List<Drama> _merge(List<Drama> previous, List<Drama> page) =>
      List.unmodifiable(
        {
          for (final row in [...previous, ...page]) row.key: row,
        }.values,
      );

  @override
  void dispose() {
    _closed = true;
    _cancel();
    catalog.removeListener(_sourceChanged);
    input.removeListener(_inputChanged);
    input.dispose();
    super.dispose();
  }
}
