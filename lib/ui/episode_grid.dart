import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/models.dart';

/// Page by list index but show and locate the source's original episode number.
class EpisodeGrid extends StatefulWidget {
  const EpisodeGrid({
    super.key,
    required this.episodes,
    required this.builder,
    required this.onJump,
    this.initialIndex = 0,
  });
  final List<Episode> episodes;
  final IndexedWidgetBuilder builder;
  final ValueChanged<int> onJump;
  final int initialIndex;
  @override
  State<EpisodeGrid> createState() => _EpisodeGridState();
}

class _EpisodeGridState extends State<EpisodeGrid> {
  static const pageSize = 30;
  late int page = widget.initialIndex ~/ pageSize;

  Future<void> _jump() async {
    var input = '';
    String? error;
    final index = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          void submit() {
            final number = int.tryParse(input);
            final index = widget.episodes.indexWhere((e) => e.number == number);
            if (index < 0) {
              update(() => error = '没有这一集，请输入已有集数');
              return;
            }
            Navigator.pop(context, index);
          }

          return AlertDialog(
            title: const Text('跳转到分集'),
            content: TextField(
              onChanged: (value) => input = value,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(labelText: '集数', errorText: error),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('播放')),
            ],
          );
        },
      ),
    );
    if (!mounted || index == null) return;
    setState(() => page = index ~/ pageSize);
    widget.onJump(index);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.episodes.length;
    if (count == 0) return const Center(child: Text('暂无分集'));
    final pages = (count / pageSize).ceil();
    final current = page.clamp(0, pages - 1);
    final start = current * pageSize;
    return Column(
      children: [
        Row(
          children: [
            if (pages > 1)
              Expanded(
                child: DropdownButton<int>(
                  value: current,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (var i = 0; i < pages; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(
                          '${widget.episodes[i * pageSize].number}–${widget.episodes[((i + 1) * pageSize - 1).clamp(0, count - 1)].number} 集',
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() => page = value!),
                ),
              )
            else
              const Spacer(),
            TextButton.icon(
              onPressed: _jump,
              icon: const Icon(Icons.pin_outlined, size: 18),
              label: const Text('跳集'),
            ),
          ],
        ),
        Expanded(
          child: GridView.builder(
            key: ValueKey(current),
            padding: const EdgeInsets.only(bottom: 24),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 80,
              mainAxisExtent: 60,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            itemCount: (count - start).clamp(0, pageSize),
            itemBuilder: (context, index) =>
                widget.builder(context, start + index),
          ),
        ),
      ],
    );
  }
}
