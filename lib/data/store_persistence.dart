abstract interface class StorePersistence {
  String? get persistenceError;
  Future<void> persist({bool records = true, bool cache = true});
}
