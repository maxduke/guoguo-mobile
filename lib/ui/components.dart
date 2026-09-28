import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../data/cover_cache.dart';

class Poster extends StatelessWidget {
  const Poster(this.drama, {super.key, this.radius = 16});
  final Drama drama;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final seed = drama.title.runes.fold<int>(0, (a, b) => a + b);
    final palettes = [
      const [Color(0xFF345D55), Color(0xFF152F2A)],
      const [Color(0xFFAA8C64), Color(0xFF594937)],
      const [Color(0xFF82958C), Color(0xFF34483F)],
    ];
    final colors = palettes[seed % palettes.length];
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: Center(
        child: LayoutBuilder(
          builder: (context, size) {
            if (size.maxWidth < 100 || size.maxHeight < 100) {
              return const Center(
                child: Icon(
                  Icons.local_movies_outlined,
                  color: Colors.white54,
                  size: 24,
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.local_movies_outlined,
                    color: Colors.white54,
                    size: 32,
                  ),
                  const SizedBox(height: 14),
                  Flexible(
                    child: Text(
                      drama.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, bounds) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: CachedNetworkImage(
          imageUrl: coverRequest(drama),
          cacheKey: coverRequest(drama),
          cacheManager: coverCache,
          fit: BoxFit.cover,
          memCacheWidth: bounds.maxWidth.isFinite
              ? (bounds.maxWidth * MediaQuery.devicePixelRatioOf(context))
                    .clamp(64, 600)
                    .round()
              : 600,
          placeholder: (_, _) => placeholder,
          errorWidget: (_, _, _) => placeholder,
        ),
      ),
    );
  }
}

class DramaCard extends StatelessWidget {
  const DramaCard({
    super.key,
    required this.drama,
    required this.onTap,
    required this.favorite,
    required this.onFavorite,
  });
  final Drama drama;
  final VoidCallback onTap, onFavorite;
  final bool favorite;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(16),
                child: Semantics(
                  label: '${drama.title}，打开详情',
                  button: true,
                  child: Poster(drama),
                ),
              ),
            ),
            Positioned(
              top: 5,
              right: 5,
              child: IconButton.filledTonal(
                tooltip: favorite ? '取消收藏' : '收藏',
                onPressed: onFavorite,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: .25),
                  foregroundColor: Colors.white,
                ),
                icon: Icon(
                  favorite
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  size: 20,
                ),
              ),
            ),
            if (drama.vip == true)
              Positioned(
                top: 10,
                left: 10,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFDBC399),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    child: Text(
                      'VIP',
                      style: TextStyle(
                        color: Color(0xFF3A2B16),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            if (drama.episodes > 0)
              Positioned(
                bottom: 9,
                left: 10,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    child: Text(
                      '${drama.episodes} 集',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 9),
      Text(
        drama.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 2),
      Text(
        drama.category.isEmpty ? drama.source.label : drama.category,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title, message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 42),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(26),
            ),
            child: Icon(
              icon,
              size: 34,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}

Future<void> perform(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class SourceFilter extends StatelessWidget {
  const SourceFilter({super.key, required this.value, required this.onChanged});
  final DramaSource? value;
  final ValueChanged<DramaSource?> onChanged;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final source in <DramaSource?>[null, ...DramaSource.values])
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(source?.label ?? '全部站源'),
              selected: source == value,
              onSelected: (_) => onChanged(source),
            ),
          ),
      ],
    ),
  );
}
