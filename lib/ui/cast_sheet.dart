import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/cast_receivers.dart';
import '../platform/cast_session.dart';

Future<void> showCastSheet(
  BuildContext context,
  CastSessionController session, {
  CastDiscovery Function()? discoveryFactory,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) =>
      CastSheet(session: session, discoveryFactory: discoveryFactory),
);

class CastSheet extends StatefulWidget {
  const CastSheet({super.key, required this.session, this.discoveryFactory});
  final CastSessionController session;
  final CastDiscovery Function()? discoveryFactory;
  @override
  State<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<CastSheet> {
  late final CastDiscovery _discovery;
  @override
  void initState() {
    super.initState();
    _discovery = (widget.discoveryFactory ?? DeviceCastDiscovery.new)();
    if (!widget.session.blocksLocal) unawaited(_discovery.refresh());
  }

  String _time(Duration duration) =>
      '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  Future<void> _stop() async {
    await widget.session.stop();
    if (mounted && !widget.session.blocksLocal) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, _discovery]),
    builder: (context, _) {
      final session = widget.session;
      final casting = session.blocksLocal;
      final controls = session.phase == CastPhase.connected;
      final position = session.reportedPosition;
      final status = switch (session.latest.state) {
        CastPlaybackState.playing => '正在播放',
        CastPlaybackState.paused => '已暂停',
        CastPlaybackState.buffering => '正在缓冲',
        CastPlaybackState.stopped => '已停止',
        CastPlaybackState.unknown => '电视未提供播放状态',
      };
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .78,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        casting
                            ? '投屏到 ${session.deviceName ?? '电视'}'
                            : '投到大屏，一起看',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      key: const Key('closeCastControls'),
                      tooltip: casting ? '收起投屏控制，继续投屏' : '关闭投屏面板',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('手机与电视需连接同一 Wi-Fi。当前通过手机传输视频，请保持果果在前台。'),
                if (casting) ...[
                  const SizedBox(height: 12),
                  const Text('收起面板后投屏继续，可从播放器重新打开；离开播放页会结束投屏。'),
                  const SizedBox(height: 16),
                  if (session.source != null) Text(session.source!.title),
                  if (controls) ...[
                    const SizedBox(height: 12),
                    Text(status),
                    if (position != null)
                      Text(
                        '电视进度 ${_time(position)}${session.duration > Duration.zero ? ' / ${_time(session.duration)}' : ''}',
                      )
                    else
                      const Text('电视未提供可确认的进度，返回手机时使用投屏前的位置。'),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: session.busy
                              ? null
                              : () => session.setPlaying(false),
                          icon: const Icon(Icons.pause),
                          label: const Text('暂停'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: session.busy
                              ? null
                              : () => session.setPlaying(true),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('继续'),
                        ),
                      ],
                    ),
                  ],
                  if (session.phase == CastPhase.connecting)
                    const Text('正在连接电视并交接进度…'),
                  if (session.phase == CastPhase.stopping)
                    const Text('正在读取最终进度并结束投屏…'),
                  if (session.phase == CastPhase.returning)
                    const Text('正在恢复手机播放位置…'),
                ],
                if (_discovery.loading && !casting || session.busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
                if (session.error != null ||
                    !casting && _discovery.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    session.error ?? _discovery.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (casting)
                  OutlinedButton.icon(
                    key: const Key('stopCasting'),
                    onPressed:
                        session.phase == CastPhase.stopping ||
                            session.phase == CastPhase.returning
                        ? null
                        : _stop,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(
                      session.phase == CastPhase.connecting
                          ? '取消连接'
                          : '结束投屏，返回手机',
                    ),
                  )
                else ...[
                  if (_discovery.devices.isEmpty && !_discovery.loading)
                    const Text('暂未发现电视，可开启电视接收端后重新搜索。'),
                  for (final device in _discovery.devices)
                    ListTile(
                      leading: const Icon(Icons.tv),
                      title: Text(device.name),
                      subtitle: Text(device.protocol),
                      onTap: () => session.start(device),
                    ),
                  OutlinedButton.icon(
                    onPressed: _discovery.loading ? null : _discovery.refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新搜索电视'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    // Discovery belongs to the sheet; media, relay and status polling do not.
    _discovery.dispose();
    super.dispose();
  }
}
