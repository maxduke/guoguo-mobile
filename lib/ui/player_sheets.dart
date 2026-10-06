import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../domain/models.dart';
import 'episode_grid.dart';

class PlayerEpisodeSheet extends StatelessWidget {
  const PlayerEpisodeSheet({
    super.key,
    required this.episodes,
    required this.index,
    required this.onSelect,
  });
  final List<Episode> episodes;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: math.min(600, MediaQuery.sizeOf(context).height * .85),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Text(
            '选集 · 共 ${episodes.length} 集',
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: EpisodeGrid(
              episodes: episodes,
              initialIndex: index,
              onJump: onSelect,
              builder: (context, selected) => FilledButton.tonal(
                onPressed: () => onSelect(selected),
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: selected == index
                      ? const Color(0xFF345D55)
                      : null,
                ),
                child: Text(
                  '${episodes[selected].number}${episodes[selected].vip ? '\nVIP' : ''}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class PlayerRelatedSheet extends StatelessWidget {
  const PlayerRelatedSheet({
    super.key,
    required this.rows,
    required this.onSelect,
  });
  final List<Drama> rows;
  final ValueChanged<Drama> onSelect;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: math.min(500, MediaQuery.sizeOf(context).height * .75),
    child: rows.isEmpty
        ? const Center(child: Text('暂未找到同系列作品'))
        : ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) => ListTile(
              title: Text(rows[index].title),
              subtitle: Text(rows[index].source.label),
              onTap: () => onSelect(rows[index]),
            ),
          ),
  );
}

enum PlayerMenuAction { related, fit, orientation, pip, cast, download, lock }

class PlayerMoreSheet extends StatelessWidget {
  const PlayerMoreSheet({
    super.key,
    required this.autoAdvance,
    required this.fill,
    required this.pipEnabled,
    required this.castEnabled,
    required this.qualities,
    required this.quality,
    required this.onAutoAdvance,
    required this.onAction,
    required this.onQuality,
  });
  final bool autoAdvance, fill, pipEnabled, castEnabled;
  final List<int> qualities;
  final int? quality;
  final ValueChanged<bool> onAutoAdvance;
  final ValueChanged<PlayerMenuAction> onAction;
  final ValueChanged<int> onQuality;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .75,
    ),
    child: ListView(
      shrinkWrap: true,
      children: [
        ListTile(
          leading: const Icon(Icons.video_library_outlined),
          title: const Text('相关剧集'),
          subtitle: const Text('按标题匹配同系列作品'),
          onTap: () => onAction(PlayerMenuAction.related),
        ),
        SwitchListTile(
          title: const Text('自动播放下一集'),
          subtitle: const Text('关闭后，播完停在当前集'),
          value: autoAdvance,
          onChanged: onAutoAdvance,
        ),
        const ListTile(
          leading: Icon(Icons.touch_app_outlined),
          title: Text('播放手势'),
          subtitle: Text(
            '单击显示或隐藏控件；上下滑动切换分集；左右滑动调节进度。长按 2 倍速，按住后左右滑动可快进快退，松手跳转。',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.fit_screen),
          title: Text(fill ? '显示完整画面' : '等比例铺满（裁切边缘）'),
          onTap: () => onAction(PlayerMenuAction.fit),
        ),
        ListTile(
          leading: const Icon(Icons.screen_rotation_outlined),
          title: const Text('切换横竖屏'),
          onTap: () => onAction(PlayerMenuAction.orientation),
        ),
        ListTile(
          leading: const Icon(Icons.picture_in_picture_alt),
          title: const Text('画中画'),
          enabled: pipEnabled,
          onTap: () => onAction(PlayerMenuAction.pip),
        ),
        ListTile(
          leading: const Icon(Icons.cast),
          title: const Text('投屏到电视'),
          enabled: castEnabled,
          onTap: () => onAction(PlayerMenuAction.cast),
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('下载当前集'),
          onTap: () => onAction(PlayerMenuAction.download),
        ),
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: const Text('锁定手势'),
          onTap: () => onAction(PlayerMenuAction.lock),
        ),
        if (qualities.length > 1)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final value in qualities)
                  ChoiceChip(
                    label: Text('${value}P'),
                    selected: value == quality,
                    onSelected: (_) => onQuality(value),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}
