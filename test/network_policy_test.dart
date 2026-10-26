import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/network_policy.dart';

void main() {
  for (final fixture in <(List<ConnectivityResult>, bool, bool, bool)>[
    ([ConnectivityResult.wifi], true, true, true),
    ([ConnectivityResult.mobile], false, false, true),
    ([ConnectivityResult.wifi, ConnectivityResult.mobile], false, false, true),
    ([ConnectivityResult.none], false, false, false),
    ([], false, false, false),
    ([ConnectivityResult.wifi, ConnectivityResult.none], false, false, false),
    ([ConnectivityResult.vpn], false, false, true),
    ([ConnectivityResult.wifi, ConnectivityResult.vpn], true, true, true),
    ([ConnectivityResult.mobile, ConnectivityResult.vpn], false, false, true),
    ([ConnectivityResult.ethernet], false, true, true),
    ([ConnectivityResult.ethernet, ConnectivityResult.vpn], false, true, true),
    (
      [ConnectivityResult.ethernet, ConnectivityResult.mobile],
      false,
      false,
      true,
    ),
    (
      [ConnectivityResult.ethernet, ConnectivityResult.none],
      false,
      false,
      false,
    ),
  ]) {
    test('prefetch permission for ${fixture.$1}', () {
      expect(isWifiNetwork(fixture.$1), fixture.$2);
      expect(allowsPrefetchNetwork(fixture.$1, cellular: false), fixture.$3);
      expect(allowsPrefetchNetwork(fixture.$1, cellular: true), fixture.$4);
    });
  }
}
