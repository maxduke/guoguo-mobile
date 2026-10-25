import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/network_policy.dart';

void main() {
  for (final fixture in <(List<ConnectivityResult>, bool, bool)>[
    ([ConnectivityResult.wifi], true, true),
    ([ConnectivityResult.mobile], false, true),
    ([ConnectivityResult.wifi, ConnectivityResult.mobile], false, true),
    ([ConnectivityResult.none], false, false),
    ([], false, false),
    ([ConnectivityResult.wifi, ConnectivityResult.none], false, false),
    ([ConnectivityResult.vpn], false, true),
    ([ConnectivityResult.wifi, ConnectivityResult.vpn], true, true),
    ([ConnectivityResult.mobile, ConnectivityResult.vpn], false, true),
    ([ConnectivityResult.ethernet], false, true),
  ]) {
    test('prefetch permission for ${fixture.$1}', () {
      expect(isWifiNetwork(fixture.$1), fixture.$2);
      expect(allowsPrefetchNetwork(fixture.$1, cellular: false), fixture.$2);
      expect(allowsPrefetchNetwork(fixture.$1, cellular: true), fixture.$3);
    });
  }
}
