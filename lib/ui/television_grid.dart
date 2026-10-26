import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'television_scope.dart';

/// Preserve item identity and move by row/column, including into lazy rows.
class TelevisionGrid extends StatefulWidget {
  const TelevisionGrid({
    super.key,
    required this.itemKeys,
    required this.columns,
    required this.mainAxisExtent,
    required this.itemBuilder,
    this.mainAxisSpacing = 22,
    this.crossAxisSpacing = 14,
    this.sliver = true,
    this.shrinkWrap = false,
    this.padding,
    this.autofocusIndex,
    this.above,
    this.below,
    this.scrollIdentity,
  }) : assert(columns > 0);

  final List<Object> itemKeys;
  final int columns;
  final double mainAxisExtent, mainAxisSpacing, crossAxisSpacing;
  final IndexedWidgetBuilder itemBuilder;
  final bool sliver, shrinkWrap;
  final EdgeInsetsGeometry? padding;
  final int? autofocusIndex;
  final FocusNode? above, below;
  final Object? scrollIdentity;

  @override
  State<TelevisionGrid> createState() => TelevisionGridState();
}

class TelevisionGridState extends State<TelevisionGrid> {
  final _cells = <Object, FocusNode>{};
  final _scroll = ScrollController();
  int _request = 0;
  Object? _lastFocusedKey;
  bool _movingToLazyRow = false;

  @override
  void initState() {
    super.initState();
    if (widget.autofocusIndex case final index?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focusItem(index);
      });
    }
  }

  @override
  void didUpdateWidget(TelevisionGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.itemKeys, widget.itemKeys)) {
      _request++;
      _movingToLazyRow = false;
    }
  }

  @override
  void dispose() {
    _request++;
    _cells.clear();
    _scroll.dispose();
    super.dispose();
  }

  bool _focus(Object key, {bool up = false}) {
    final cell = _cells[key];
    if (cell?.context == null) return false;
    final target = cell!.descendants
        .where((node) => node.canRequestFocus && !node.skipTraversal)
        .firstOrNull;
    if (target?.context == null) return false;
    FocusTraversalGroup.of(
      target!.context!,
    ).invalidateScopeData(target.nearestScope!);
    FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
      target,
      alignment: up ? 0 : 1,
      alignmentPolicy: up
          ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
          : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
    return true;
  }

  /// Used by page changes and "locate current" after their layout is updated.
  void focusItem([int? index]) {
    final lastKey = _lastFocusedKey;
    index ??= lastKey == null
        ? 0
        : math.max(0, widget.itemKeys.indexOf(lastKey));
    if (!mounted ||
        !TelevisionScope.of(context) ||
        index < 0 ||
        index >= widget.itemKeys.length ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final request = ++_request;
    _movingToLazyRow = false;
    final key = widget.itemKeys[index];
    if (_focus(key)) return;
    if (_scroll.hasClients) {
      final origin = FocusManager.instance.primaryFocus;
      _scroll.jumpTo(
        ((index ~/ widget.columns) *
                (widget.mainAxisExtent + widget.mainAxisSpacing))
            .clamp(0, _scroll.position.maxScrollExtent),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            request == _request &&
            (origin == FocusManager.instance.primaryFocus ||
                FocusManager.instance.primaryFocus is FocusScopeNode) &&
            ModalRoute.of(context)?.isCurrent != false) {
          _focus(key);
        }
      });
    }
  }

  KeyEventResult _move(int index, FocusNode cell, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final columns = widget.columns;
    final count = widget.itemKeys.length;
    final key = event.logicalKey;
    if (_movingToLazyRow &&
        {
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
        }.contains(key)) {
      return KeyEventResult.handled;
    }
    final target = switch (key) {
      LogicalKeyboardKey.arrowLeft when index % columns > 0 => index - 1,
      LogicalKeyboardKey.arrowRight
          when index % columns < columns - 1 && index < count - 1 =>
        index + 1,
      LogicalKeyboardKey.arrowUp when index >= columns => index - columns,
      LogicalKeyboardKey.arrowDown
          when index ~/ columns < (count - 1) ~/ columns =>
        math.min(index + columns, count - 1),
      _ => null,
    };
    if (target == null) {
      final exit = switch (key) {
        LogicalKeyboardKey.arrowUp => widget.above,
        LogicalKeyboardKey.arrowDown => widget.below,
        _ => null,
      };
      if (exit?.context != null && exit!.canRequestFocus) {
        FocusTraversalPolicy.defaultTraversalRequestFocusCallback(exit);
        return KeyEventResult.handled;
      }
      // Never wrap Right into another row. Other edges can reach the rail,
      // filters, or paging controls outside the grid.
      return key == LogicalKeyboardKey.arrowRight
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    final up = target < index;
    final request = ++_request;
    final targetKey = widget.itemKeys[target];
    if (!_focus(targetKey, up: up)) {
      final current = cell.context;
      final position = current == null
          ? null
          : Scrollable.maybeOf(current)?.position;
      if (position != null) {
        _movingToLazyRow = true;
        final rows = target ~/ columns - index ~/ columns;
        position.jumpTo(
          (position.pixels +
                  rows * (widget.mainAxisExtent + widget.mainAxisSpacing))
              .clamp(position.minScrollExtent, position.maxScrollExtent),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || request != _request) return;
          _movingToLazyRow = false;
          if (cell.hasFocus && ModalRoute.of(context)?.isCurrent != false) {
            _focus(targetKey, up: up);
          }
        });
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final television = TelevisionScope.of(context);
    final indices = {
      for (var i = 0; i < widget.itemKeys.length; i++) widget.itemKeys[i]: i,
    };
    final children = SliverChildBuilderDelegate(
      (context, index) {
        final key = widget.itemKeys[index];
        Widget child = widget.itemBuilder(context, index);
        if (television) {
          child = _TelevisionGridCell(
            grid: this,
            index: index,
            itemKey: key,
            child: child,
          );
        }
        return KeyedSubtree(key: ValueKey(key), child: child);
      },
      childCount: widget.itemKeys.length,
      findChildIndexCallback: (key) =>
          key is ValueKey ? indices[key.value] : null,
    );
    final layout = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: widget.columns,
      mainAxisExtent: widget.mainAxisExtent,
      mainAxisSpacing: widget.mainAxisSpacing,
      crossAxisSpacing: widget.crossAxisSpacing,
    );
    if (widget.sliver) {
      return SliverGrid(delegate: children, gridDelegate: layout);
    }
    return GridView.custom(
      key: ValueKey(widget.scrollIdentity),
      controller: _scroll,
      shrinkWrap: widget.shrinkWrap,
      physics: widget.shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: widget.padding,
      gridDelegate: layout,
      childrenDelegate: children,
    );
  }
}

// Only mounted cells retain nodes. Button focus keeps the selected cell alive;
// lazy rows outside the viewport can release their entire subtree.
class _TelevisionGridCell extends StatefulWidget {
  const _TelevisionGridCell({
    required this.grid,
    required this.index,
    required this.itemKey,
    required this.child,
  });
  final TelevisionGridState grid;
  final int index;
  final Object itemKey;
  final Widget child;

  @override
  State<_TelevisionGridCell> createState() => _TelevisionGridCellState();
}

class _TelevisionGridCellState extends State<_TelevisionGridCell> {
  late final _focus = FocusNode(debugLabel: 'tv-grid-${widget.itemKey}');

  @override
  void initState() {
    super.initState();
    widget.grid._cells[widget.itemKey] = _focus;
  }

  @override
  void dispose() {
    if (widget.grid._cells[widget.itemKey] == _focus) {
      widget.grid._cells.remove(widget.itemKey);
    }
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    canRequestFocus: false,
    skipTraversal: true,
    includeSemantics: false,
    onFocusChange: (focused) {
      if (focused) widget.grid._lastFocusedKey = widget.itemKey;
    },
    onKeyEvent: (cell, event) => widget.grid._move(widget.index, cell, event),
    child: widget.child,
  );
}
