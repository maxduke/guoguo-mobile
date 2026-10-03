import 'search_cache.dart';

class SeriesLookup {
  SeriesLookup(this.result, this.cancel);
  final Future<CatalogSearchResult> result;
  final void Function() cancel;
}

class SeriesLookupCancelled implements Exception {
  const SeriesLookupCancelled();
}
