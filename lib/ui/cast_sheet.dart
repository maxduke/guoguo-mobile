import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import '../domain/models.dart';
import '../platform/casting.dart';
import 'components.dart';

Future<void> showCastSheet(
  BuildContext context,
  ResolvedMedia media,
  String title,
  String? localPath, {
  required Future<void> Function() onConnected,
}) => showModalBottomSheet<void>(
  context: context,
  isDismissible: false,
  enableDrag: false,
  isScrollControlled: true,
  builder: (_) => CastSheet(
    media: media,
    title: title,
    localPath: localPath,
    onConnected: onConnected,
  ),
);

class CastSheet extends StatefulWidget {
  const CastSheet({
    super.key,
    required this.media,
    required this.title,
    required this.localPath,
    required this.onConnected,
  });
  final ResolvedMedia media;
  final String title;
  final String? localPath;
  final Future<void> Function() onConnected;
  @override
  State<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<CastSheet> {
  List<GoogleCastDevice> _cast = [];
  List<DlnaDevice> _dlna = [];
  StreamSubscription<List<GoogleCastDevice>>? _subscription;
  CastRelay? _relay;
  DlnaDevice? _connectedDlna;
  String? _connected, _error;
  bool _loading = true, _connecting = false;
  static bool _initialized = false;
  @override
  void initState() {
    super.initState();
    unawaited(_discover());
  }

  Future<void> _discover() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!_initialized) {
        const appId = GoogleCastDiscoveryCriteria.kDefaultApplicationId;
        await GoogleCastContext.instance.setSharedInstanceWithOptions(
          Platform.isIOS
              ? IOSGoogleCastOptions(
                  GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(
                    appId,
                  ),
                  stopCastingOnAppTerminated: true,
                )
              : GoogleCastOptionsAndroid(
                  appId: appId,
                  stopCastingOnAppTerminated: true,
                ),
        );
        _initialized = true;
      }
      _subscription ??= GoogleCastDiscoveryManager.instance.devicesStream
          .listen((devices) {
            if (mounted) setState(() => _cast = devices);
          });
      await GoogleCastDiscoveryManager.instance.startDiscovery();
      _cast = GoogleCastDiscoveryManager.instance.devices;
    } catch (error) {
      if (mounted) setState(() => _error = 'Google Cast 搜索未启动，请检查本地网络权限');
    }
    try {
      final devices = await discoverDlna();
      if (mounted) setState(() => _dlna = devices);
    } catch (_) {
      if (mounted) setState(() => _error = '请允许本地网络访问，并确认电视已打开投屏接收');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _connect({GoogleCastDevice? cast, DlnaDevice? dlna}) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      await _relay?.close();
      _relay = CastRelay();
      final url = await _relay!.start(widget.media, widget.localPath);
      if (cast != null) {
        await GoogleCastSessionManager.instance.startSessionWithDevice(cast);
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (GoogleCastSessionManager.instance.connectionState !=
            GoogleCastConnectState.connected) {
          if (!mounted || DateTime.now().isAfter(deadline)) {
            throw Exception('连接电视超时');
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        await GoogleCastRemoteMediaClient.instance.loadMedia(
          GoogleCastMediaInformation(
            contentId: url,
            contentUrl: Uri.parse(url),
            streamType: CastMediaStreamType.buffered,
            contentType: widget.media.hls && widget.localPath == null
                ? 'application/x-mpegURL'
                : 'video/mp4',
            metadata: GoogleCastMovieMediaMetadata(title: widget.title),
          ),
        );
      } else {
        await dlna!.play(url);
        _connectedDlna = dlna;
      }
      await widget.onConnected();
      if (mounted) {
        setState(() => _connected = cast?.friendlyName ?? dlna!.name);
      }
    } catch (error) {
      await _relay?.close();
      _relay = null;
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _stop() async {
    try {
      if (_connectedDlna != null) {
        await _connectedDlna!.command('Stop', {});
      } else if (_connected != null) {
        await GoogleCastSessionManager.instance.endSessionAndStopCasting();
      }
    } finally {
      await _relay?.close();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _connected == null,
    child: SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _connected == null ? '投到大屏，一起看' : '正在投屏到 $_connected',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              const Text('手机与电视需连接同一 Wi-Fi。当前通过手机传输视频，投屏期间请保持果果在前台。'),
              const SizedBox(height: 16),
              if (_loading || _connecting) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: _connected != null
                    ? Center(
                        child: Wrap(
                          spacing: 16,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () => perform(context, () async {
                                if (_connectedDlna != null) {
                                  await _connectedDlna!.command('Pause', {});
                                } else {
                                  await GoogleCastRemoteMediaClient.instance
                                      .pause();
                                }
                              }),
                              icon: const Icon(Icons.pause),
                              label: const Text('暂停'),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: () => perform(context, () async {
                                if (_connectedDlna != null) {
                                  await _connectedDlna!.command('Play', {
                                    'Speed': '1',
                                  });
                                } else {
                                  await GoogleCastRemoteMediaClient.instance
                                      .play();
                                }
                              }),
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('继续'),
                            ),
                          ],
                        ),
                      )
                    : ListView(
                        children: [
                          for (final device in _cast)
                            ListTile(
                              leading: const Icon(Icons.cast),
                              title: Text(device.friendlyName),
                              subtitle: const Text('Google Cast'),
                              onTap: _connecting
                                  ? null
                                  : () => _connect(cast: device),
                            ),
                          for (final device in _dlna)
                            ListTile(
                              leading: const Icon(Icons.tv),
                              title: Text(device.name),
                              subtitle: const Text('DLNA'),
                              onTap: _connecting
                                  ? null
                                  : () => _connect(dlna: device),
                            ),
                          if (!_loading && _cast.isEmpty && _dlna.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 20),
                              child: Text(
                                '还没发现设备。请在电视上打开投屏接收功能，或使用播放器右上角的 AirPlay。',
                              ),
                            ),
                        ],
                      ),
              ),
              Row(
                children: [
                  if (_connected == null)
                    TextButton(
                      onPressed: _loading ? null : _discover,
                      child: const Text('重新搜索'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _connecting
                        ? null
                        : () => perform(context, _stop),
                    child: Text(_connected == null ? '返回' : '停止投屏并返回'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  @override
  void dispose() {
    _subscription?.cancel();
    unawaited(_relay?.close());
    if (_initialized) {
      unawaited(GoogleCastDiscoveryManager.instance.stopDiscovery());
    }
    super.dispose();
  }
}
