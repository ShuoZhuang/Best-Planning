import 'package:flutter/material.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

final class ScheduleCategorySummary {
  const ScheduleCategorySummary({
    required this.categoryKey,
    required this.categoryLabel,
    required this.categoryColorArgb,
    required this.categorySortOrder,
    required this.minutes,
  });

  final String categoryKey;
  final String categoryLabel;
  final int categoryColorArgb;
  final int categorySortOrder;
  final int minutes;

  Color get categoryColor => Color(categoryColorArgb);
}

List<ScheduleCategorySummary> summarizeScheduleCategories(
  Iterable<ScheduleViewItem> items,
) {
  final totals = <String, ScheduleCategorySummary>{};
  for (final item in items) {
    final existing = totals[item.categoryKey];
    totals[item.categoryKey] = ScheduleCategorySummary(
      categoryKey: item.categoryKey,
      categoryLabel: existing?.categoryLabel ?? item.categoryLabel,
      categoryColorArgb: existing?.categoryColorArgb ?? item.categoryColorArgb,
      categorySortOrder: existing?.categorySortOrder ?? item.categorySortOrder,
      minutes: (existing?.minutes ?? 0) + item.range.durationMinutes,
    );
  }

  final result = totals.values.toList()
    ..sort((left, right) {
      final order = left.categorySortOrder.compareTo(right.categorySortOrder);
      if (order != 0) return order;
      final label = left.categoryLabel.compareTo(right.categoryLabel);
      if (label != 0) return label;
      return left.categoryKey.compareTo(right.categoryKey);
    });
  return result;
}
