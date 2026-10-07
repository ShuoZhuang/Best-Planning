import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/area_palette.dart';

void main() {
  test('色板提供八种可命名的不透明颜色供领域和特殊分类选择', () {
    expect(areaPaletteArgb, hasLength(greaterThanOrEqualTo(8)));
    expect(areaPaletteNames, hasLength(areaPaletteArgb.length));
    expect(
      areaPaletteArgb.every(
        (color) => color >= 0xff000000 && color <= 0xffffffff,
      ),
      isTrue,
    );
  });

  test('五个默认领域和三个特殊分类拿到互不相同的初始颜色', () {
    final defaults = <int>{
      ...List<int>.generate(5, (index) => resolveAreaColorArgb(0, index)),
      defaultProtectedTimeArgb,
      defaultUnassignedTaskArgb,
      defaultUnassignedFixedArgb,
    };

    expect(defaults, hasLength(8));
  });

  test('已保存颜色优先于排序回退', () {
    expect(resolveAreaColorArgb(0xff123456, 7), 0xff123456);
    expect(hasCustomAreaColor(0xff123456), isTrue);
    expect(hasCustomAreaColor(0), isFalse);
  });

  test('未设置颜色按排序稳定循环，负排序回到首色', () {
    expect(resolveAreaColorArgb(0, 0), areaPaletteArgb[0]);
    expect(resolveAreaColorArgb(0, areaPaletteArgb.length), areaPaletteArgb[0]);
    expect(resolveAreaColorArgb(0, -1), areaPaletteArgb[0]);
  });
}
