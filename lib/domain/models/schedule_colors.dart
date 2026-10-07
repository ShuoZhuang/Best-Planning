import 'package:personal_planner/core/area_palette.dart';

enum ScheduleSpecialCategory { protectedTime, unassignedTask, unassignedFixed }

final class ScheduleSpecialColors {
  const ScheduleSpecialColors({
    required this.protectedTime,
    required this.unassignedTask,
    required this.unassignedFixed,
  });

  static const defaults = ScheduleSpecialColors(
    protectedTime: defaultProtectedTimeArgb,
    unassignedTask: defaultUnassignedTaskArgb,
    unassignedFixed: defaultUnassignedFixedArgb,
  );

  final int protectedTime;
  final int unassignedTask;
  final int unassignedFixed;

  int colorOf(ScheduleSpecialCategory category) => switch (category) {
    ScheduleSpecialCategory.protectedTime => protectedTime,
    ScheduleSpecialCategory.unassignedTask => unassignedTask,
    ScheduleSpecialCategory.unassignedFixed => unassignedFixed,
  };

  ScheduleSpecialColors copyWith({
    int? protectedTime,
    int? unassignedTask,
    int? unassignedFixed,
  }) => ScheduleSpecialColors(
    protectedTime: protectedTime ?? this.protectedTime,
    unassignedTask: unassignedTask ?? this.unassignedTask,
    unassignedFixed: unassignedFixed ?? this.unassignedFixed,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'protectedTimeArgb': protectedTime,
    'unassignedTaskArgb': unassignedTask,
    'unassignedFixedArgb': unassignedFixed,
  };

  factory ScheduleSpecialColors.fromJson(Object? value) {
    if (value is! Map) return defaults;
    return ScheduleSpecialColors(
      protectedTime: _validColorOr(
        value['protectedTimeArgb'],
        defaults.protectedTime,
      ),
      unassignedTask: _validColorOr(
        value['unassignedTaskArgb'],
        defaults.unassignedTask,
      ),
      unassignedFixed: _validColorOr(
        value['unassignedFixedArgb'],
        defaults.unassignedFixed,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduleSpecialColors &&
      other.protectedTime == protectedTime &&
      other.unassignedTask == unassignedTask &&
      other.unassignedFixed == unassignedFixed;

  @override
  int get hashCode =>
      Object.hash(protectedTime, unassignedTask, unassignedFixed);
}

final class ScheduleCategoryPresentation {
  const ScheduleCategoryPresentation({
    required this.key,
    required this.label,
    required this.colorArgb,
    required this.sortOrder,
  });

  final String key;
  final String label;
  final int colorArgb;
  final int sortOrder;
}

final class ScheduleColorCatalog {
  ScheduleColorCatalog({
    required Map<String, ScheduleCategoryPresentation> areas,
    required Map<ScheduleSpecialCategory, ScheduleCategoryPresentation>
    specials,
  }) : _areas = Map.unmodifiable(areas),
       _specials = Map.unmodifiable(specials);

  final Map<String, ScheduleCategoryPresentation> _areas;
  final Map<ScheduleSpecialCategory, ScheduleCategoryPresentation> _specials;

  ScheduleCategoryPresentation forAreaOrSpecial({
    required String? areaId,
    required ScheduleSpecialCategory fallback,
  }) => (areaId == null ? null : _areas[areaId]) ?? _specials[fallback]!;

  ScheduleCategoryPresentation special(ScheduleSpecialCategory category) =>
      _specials[category]!;
}

int _validColorOr(Object? value, int fallback) =>
    value is int && isOpaqueArgb(value) ? value : fallback;
