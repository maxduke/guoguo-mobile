import 'package:connectivity_plus/connectivity_plus.dart';

/// Transport capabilities are not proof of internet access or the billed route.
bool isOfflineNetwork(List<ConnectivityResult> states) =>
    states.isEmpty || states.contains(ConnectivityResult.none);

bool isWifiNetwork(List<ConnectivityResult> states) =>
    !isOfflineNetwork(states) &&
    states.contains(ConnectivityResult.wifi) &&
    !states.contains(ConnectivityResult.mobile);

bool allowsPrefetchNetwork(
  List<ConnectivityResult> states, {
  required bool cellular,
}) =>
    !isOfflineNetwork(states) &&
    (cellular ||
        !states.contains(ConnectivityResult.mobile) &&
            (states.contains(ConnectivityResult.wifi) ||
                states.contains(ConnectivityResult.ethernet)));
