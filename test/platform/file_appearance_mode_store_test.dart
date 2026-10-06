import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/platform/files/file_appearance_mode_store.dart';

void main() {
  test('外观兜底文件写入后可由新实例读取', () async {
    final directory = await Directory.systemTemp.createTemp(
      'planner-appearance-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}appearance-mode';

    await FileAppearanceModeStore(path).write('liquid');

    expect(await FileAppearanceModeStore(path).read(), 'liquid');
  });

  test('生产环境把外观设置放在系统授权的应用 Support 目录', () {
    final supportDirectory =
        'C:${Platform.pathSeparator}AppData${Platform.pathSeparator}Local${Platform.pathSeparator}Packages${Platform.pathSeparator}Planner${Platform.pathSeparator}LocalState';
    final path = appearanceModePathIn(supportDirectory);

    expect(
      path,
      '$supportDirectory${Platform.pathSeparator}personal_planner.appearance-mode',
    );
  });

  test('带包身份时由 AUMID 定位对应的 LocalState 沙箱', () {
    final localAppData =
        'C:${Platform.pathSeparator}Users${Platform.pathSeparator}student${Platform.pathSeparator}AppData${Platform.pathSeparator}Local';

    expect(
      packagedAppearanceSupportDirectory(
        localAppData: localAppData,
        applicationUserModelId:
            'ShuoZhuang.PersonalPlanner_v9555qkaxdyym!personalplanner',
      ),
      '$localAppData${Platform.pathSeparator}Packages${Platform.pathSeparator}ShuoZhuang.PersonalPlanner_v9555qkaxdyym${Platform.pathSeparator}LocalState',
    );
  });

  test('通过真实写入探针跳过不可用候选目录', () async {
    final root = await Directory.systemTemp.createTemp(
      'planner-appearance-path-',
    );
    addTearDown(() => root.delete(recursive: true));
    final blockingFile = File(
      '${root.path}${Platform.pathSeparator}not-a-directory',
    )..writeAsStringSync('occupied');
    final writable = Directory('${root.path}${Platform.pathSeparator}writable');

    final selected = await resolveWritableAppearanceDirectory([
      Directory(blockingFile.path),
      writable,
    ]);

    expect(selected.path, writable.path);
    expect(
      await File(
        '${writable.path}${Platform.pathSeparator}.appearance-write-probe',
      ).exists(),
      isFalse,
    );
  });
}
