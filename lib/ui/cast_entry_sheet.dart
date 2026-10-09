import 'package:flutter/material.dart';

import '../platform/airplay_session.dart';

enum CastEntryAction { television, airPlay, routes, returnToPhone }

class CastEntrySheet extends StatelessWidget {
  const CastEntrySheet({
    super.key,
    required this.airplay,
    required this.televisionEnabled,
    required this.airPlayEnabled,
    required this.routesEnabled,
    required this.returnEnabled,
    required this.returnPending,
    required this.returning,
    required this.unavailableReason,
    required this.onAction,
  });

  final AirPlaySession? airplay;
  final bool televisionEnabled, airPlayEnabled, routesEnabled, returnEnabled;
  final bool returnPending, returning;
  final String? unavailableReason;
  final ValueChanged<CastEntryAction> onAction;

  @override
  Widget build(BuildContext context) {
    final session = airplay;
    final engaged = session?.engaged == true;
    final routed = session?.routed == true;
    final preparing = session?.preparing == true;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .75,
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Semantics(
            header: true,
            child: Text('投屏', style: Theme.of(context).textTheme.titleLarge),
          ),
          const SizedBox(height: 12),
          if (returning)
            const Text('正在返回手机播放…')
          else if (preparing)
            const Text('正在准备 AirPlay…')
          else if (engaged)
            Text(routed ? 'AirPlay 已连接' : 'AirPlay 播放器已打开')
          else if (routed)
            const Text('AirPlay 仍连接电视，手机播放已暂停'),
          if (engaged) ...[
            const SizedBox(height: 8),
            const Text('请在系统播放器中选择设备或结束播放'),
          ],
          if (returnPending) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: returnEnabled
                  ? () => onAction(CastEntryAction.returnToPhone)
                  : null,
              icon: const Icon(Icons.phone_iphone),
              label: const Text('结束 AirPlay，返回手机'),
            ),
          ],
          if (session != null && !engaged)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.airplay),
              title: const Text('AirPlay'),
              subtitle: const Text('使用系统播放器和 AirPlay 设备选择'),
              enabled: airPlayEnabled,
              onTap: () => onAction(CastEntryAction.airPlay),
            ),
          if (routed && !engaged)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.speaker_phone),
              title: const Text('选择 AirPlay 设备'),
              subtitle: const Text('选择 iPhone 后恢复手机播放'),
              enabled: routesEnabled,
              onTap: () => onAction(CastEntryAction.routes),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cast),
            title: const Text('电视设备'),
            subtitle: Text(
              engaged || routed || returnPending
                  ? '返回手机播放后，可使用 Cast / DLNA'
                  : '搜索 Cast / DLNA 接收设备',
            ),
            enabled: televisionEnabled,
            onTap: () => onAction(CastEntryAction.television),
          ),
          if (unavailableReason != null) ...[
            const SizedBox(height: 8),
            Text(unavailableReason!),
          ],
        ],
      ),
    );
  }
}
