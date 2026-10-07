import 'package:flutter/material.dart';
import 'package:personal_planner/core/area_palette.dart';

Future<int?> showScheduleColorPickerDialog(
  BuildContext context, {
  required String categoryLabel,
  required int selectedArgb,
}) => showDialog<int>(
  context: context,
  builder: (context) => AlertDialog(
    title: Row(
      children: [
        Expanded(child: Text('设置“$categoryLabel”颜色')),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (var index = 0; index < areaPaletteArgb.length; index++)
            _ColorSwatch(
              index: index,
              colorArgb: areaPaletteArgb[index],
              name: areaPaletteNames[index],
              selected: areaPaletteArgb[index] == selectedArgb,
              onSelected: () =>
                  Navigator.of(context).pop(areaPaletteArgb[index]),
            ),
        ],
      ),
    ),
  ),
);

final class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.index,
    required this.colorArgb,
    required this.name,
    required this.selected,
    required this.onSelected,
  });

  final int index;
  final int colorArgb;
  final String name;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final label = selected ? '$name，当前已选择' : '设为$name';
    return Semantics(
      key: Key('color-swatch-$index'),
      label: label,
      button: true,
      selected: selected,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: SizedBox.square(
          dimension: 44,
          child: TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size.square(44),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: selected
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).colorScheme.outline,
                  width: selected ? 2 : 1,
                ),
              ),
              backgroundColor: Color(colorArgb),
              foregroundColor: Colors.white,
            ),
            onPressed: onSelected,
            child: selected
                ? Icon(
                    Icons.check,
                    key: Key('selected-color-$index'),
                    shadows: const [Shadow(blurRadius: 3)],
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
