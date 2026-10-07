import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/features/calendar/schedule_category_summary.dart';

final class ScheduleCategoryLegend extends StatelessWidget {
  const ScheduleCategoryLegend({required this.summaries, super.key});

  final List<ScheduleCategorySummary> summaries;

  @override
  Widget build(BuildContext context) {
    if (summaries.isEmpty) return const SizedBox.shrink();
    return Wrap(
      key: const Key('schedule-category-legend'),
      spacing: 12,
      runSpacing: 6,
      children: [
        for (final summary in summaries)
          Semantics(
            label: '${summary.categoryLabel}分类',
            child: Row(
              key: ValueKey('schedule-category-${summary.categoryKey}'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: summary.categoryColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  summary.categoryLabel,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: PlannerPalette.textSecondary),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
