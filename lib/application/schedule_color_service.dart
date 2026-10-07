import 'dart:convert';

import 'package:personal_planner/core/area_palette.dart';
import 'package:personal_planner/domain/models/schedule_colors.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';

final class ScheduleColorService {
  const ScheduleColorService({required this.settings, required this.workspace});

  static const String storageKey = 'schedule.colors.v1';

  final SettingsRepository settings;
  final WorkspaceRepository workspace;

  Future<ScheduleSpecialColors> loadSpecialColors() async {
    try {
      final raw = await settings.read(storageKey);
      if (raw == null || raw.isEmpty) return ScheduleSpecialColors.defaults;
      return ScheduleSpecialColors.fromJson(jsonDecode(raw));
    } on Object {
      return ScheduleSpecialColors.defaults;
    }
  }

  Future<void> setSpecialColor(
    ScheduleSpecialCategory category,
    int colorArgb,
  ) async {
    if (!isOpaqueArgb(colorArgb)) {
      throw ArgumentError.value(
        colorArgb,
        'colorArgb',
        'Must be an opaque 32-bit ARGB color.',
      );
    }

    final current = await loadSpecialColors();
    final updated = switch (category) {
      ScheduleSpecialCategory.protectedTime => current.copyWith(
        protectedTime: colorArgb,
      ),
      ScheduleSpecialCategory.unassignedTask => current.copyWith(
        unassignedTask: colorArgb,
      ),
      ScheduleSpecialCategory.unassignedFixed => current.copyWith(
        unassignedFixed: colorArgb,
      ),
    };
    await settings.write(storageKey, jsonEncode(updated.toJson()));
  }

  Future<ScheduleColorCatalog> loadCatalog() async {
    final areas = await workspace.listAreas();
    final specialColors = await loadSpecialColors();
    return ScheduleColorCatalog(
      areas: <String, ScheduleCategoryPresentation>{
        for (final area in areas)
          area.id: ScheduleCategoryPresentation(
            key: 'area:${area.id}',
            label: area.name,
            colorArgb: resolveAreaColorArgb(area.color, area.sortOrder),
            sortOrder: area.sortOrder,
          ),
      },
      specials: <ScheduleSpecialCategory, ScheduleCategoryPresentation>{
        ScheduleSpecialCategory.protectedTime: ScheduleCategoryPresentation(
          key: 'special:protected',
          label: '保护时间',
          colorArgb: specialColors.protectedTime,
          sortOrder: 10000,
        ),
        ScheduleSpecialCategory.unassignedTask: ScheduleCategoryPresentation(
          key: 'special:unassigned-task',
          label: '无领域任务',
          colorArgb: specialColors.unassignedTask,
          sortOrder: 10001,
        ),
        ScheduleSpecialCategory.unassignedFixed: ScheduleCategoryPresentation(
          key: 'special:unassigned-fixed',
          label: '无领域固定日程',
          colorArgb: specialColors.unassignedFixed,
          sortOrder: 10002,
        ),
      },
    );
  }
}
