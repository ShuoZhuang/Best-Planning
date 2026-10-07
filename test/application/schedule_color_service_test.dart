import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
import 'package:personal_planner/core/area_palette.dart';
import 'package:personal_planner/domain/models/schedule_colors.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';

final class _Workspace implements WorkspaceRepository {
  _Workspace([List<PlannerArea> areas = const []]) : _areas = [...areas];

  final List<PlannerArea> _areas;

  @override
  Future<List<PlannerArea>> listAreas() async => List.unmodifiable(_areas);

  @override
  Future<List<PlannerProject>> listProjects() async => const [];

  @override
  Future<void> saveArea(PlannerArea area) async {
    final index = _areas.indexWhere((item) => item.id == area.id);
    if (index < 0) {
      _areas.add(area);
    } else {
      _areas[index] = area;
    }
  }

  @override
  Future<void> saveProject(PlannerProject project) async {}
}

final class _UnreadableSettings implements SettingsRepository {
  @override
  Future<String?> read(String key) => throw StateError('unreadable');

  @override
  Future<void> remove(String key) async {}

  @override
  Future<void> write(String key, String value) async {}
}

PlannerArea _area({
  required String id,
  required String name,
  required int color,
  required int sortOrder,
}) => PlannerArea(
  id: id,
  name: name,
  color: color,
  sortOrder: sortOrder,
  createdAtUtc: DateTime.utc(2026),
  updatedAtUtc: DateTime.utc(2026),
);

void main() {
  late MemorySettingsRepository settings;

  setUp(() {
    settings = MemorySettingsRepository();
  });

  ScheduleColorService service([WorkspaceRepository? workspace]) =>
      ScheduleColorService(
        settings: settings,
        workspace: workspace ?? _Workspace(),
      );

  test('没有设置时返回三个互不混淆的默认特殊颜色', () async {
    final colors = await service().loadSpecialColors();

    expect(colors.protectedTime, defaultProtectedTimeArgb);
    expect(colors.unassignedTask, defaultUnassignedTaskArgb);
    expect(colors.unassignedFixed, defaultUnassignedFixedArgb);
  });

  test('完整特殊颜色设置可以保存并由新服务实例读回', () async {
    final first = service();
    await first.setSpecialColor(
      ScheduleSpecialCategory.protectedTime,
      0xff112233,
    );
    await first.setSpecialColor(
      ScheduleSpecialCategory.unassignedTask,
      0xff223344,
    );
    await first.setSpecialColor(
      ScheduleSpecialCategory.unassignedFixed,
      0xff334455,
    );

    final restored = await service().loadSpecialColors();
    expect(restored.protectedTime, 0xff112233);
    expect(restored.unassignedTask, 0xff223344);
    expect(restored.unassignedFixed, 0xff334455);
  });

  test('损坏 JSON 不阻断读取并整体回退默认值', () async {
    await settings.write(ScheduleColorService.storageKey, '{bad json');

    expect(await service().loadSpecialColors(), ScheduleSpecialColors.defaults);
  });

  test('设置仓库读取失败时仍返回默认值', () async {
    final colors = ScheduleColorService(
      settings: _UnreadableSettings(),
      workspace: _Workspace(),
    );

    expect(await colors.loadSpecialColors(), ScheduleSpecialColors.defaults);
  });

  test('缺失或类型错误的字段逐项回退，不覆盖有效字段', () async {
    await settings.write(
      ScheduleColorService.storageKey,
      jsonEncode(<String, Object?>{
        'protectedTimeArgb': 0xff123456,
        'unassignedTaskArgb': 'not-an-int',
      }),
    );

    final colors = await service().loadSpecialColors();
    expect(colors.protectedTime, 0xff123456);
    expect(colors.unassignedTask, defaultUnassignedTaskArgb);
    expect(colors.unassignedFixed, defaultUnassignedFixedArgb);
  });

  test('透明、负数和超出 32 位的字段分别回退默认值', () async {
    await settings.write(
      ScheduleColorService.storageKey,
      jsonEncode(<String, Object?>{
        'protectedTimeArgb': 0x00123456,
        'unassignedTaskArgb': -1,
        'unassignedFixedArgb': 0x1ffffffff,
      }),
    );

    expect(await service().loadSpecialColors(), ScheduleSpecialColors.defaults);
  });

  test('更新一个特殊颜色时保留另外两个已保存值', () async {
    await settings.write(
      ScheduleColorService.storageKey,
      jsonEncode(<String, Object?>{
        'protectedTimeArgb': 0xff111111,
        'unassignedTaskArgb': 0xff222222,
        'unassignedFixedArgb': 0xff333333,
      }),
    );

    await service().setSpecialColor(
      ScheduleSpecialCategory.unassignedTask,
      0xffabcdef,
    );

    final colors = await service().loadSpecialColors();
    expect(colors.protectedTime, 0xff111111);
    expect(colors.unassignedTask, 0xffabcdef);
    expect(colors.unassignedFixed, 0xff333333);
  });

  test('两个特殊分类允许保存同一种颜色', () async {
    final colors = service();
    await colors.setSpecialColor(
      ScheduleSpecialCategory.unassignedTask,
      0xff778899,
    );
    await colors.setSpecialColor(
      ScheduleSpecialCategory.unassignedFixed,
      0xff778899,
    );

    final restored = await colors.loadSpecialColors();
    expect(restored.unassignedTask, restored.unassignedFixed);
  });

  test('拒绝保存透明或越界的特殊颜色', () async {
    final colors = service();

    await expectLater(
      colors.setSpecialColor(ScheduleSpecialCategory.protectedTime, 0x00123456),
      throwsArgumentError,
    );
    expect(await settings.read(ScheduleColorService.storageKey), isNull);
  });

  test('颜色目录解析历史零值领域并为失效领域选择指定回退分类', () async {
    final colors = service(
      _Workspace([_area(id: 'study', name: '学业', color: 0, sortOrder: 2)]),
    );

    final catalog = await colors.loadCatalog();
    final study = catalog.forAreaOrSpecial(
      areaId: 'study',
      fallback: ScheduleSpecialCategory.unassignedTask,
    );
    final missing = catalog.forAreaOrSpecial(
      areaId: 'deleted',
      fallback: ScheduleSpecialCategory.unassignedFixed,
    );

    expect(study.key, 'area:study');
    expect(study.label, '学业');
    expect(study.colorArgb, areaPaletteArgb[2]);
    expect(missing.key, 'special:unassigned-fixed');
    expect(missing.label, '无领域固定日程');
  });
}
