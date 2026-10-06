// 领域色板的取色规则。这里的每一条都是"历史库没有颜色"这个事实的结果：列一直存在，
// 但建表以来的写入路径都写 0，因此取色必须把 0 当作"未设置"来兜底，而不是当成黑色。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/area_palette.dart';

void main() {
  test('未设置颜色的领域按排序落到色板上', () {
    for (var order = 0; order < areaPaletteArgb.length; order++) {
      expect(
        resolveAreaColorArgb(storedColor: 0, sortOrder: order),
        areaPaletteArgb[order],
      );
    }
  });

  test('超出色板长度时循环取色，不会越界', () {
    expect(
      resolveAreaColorArgb(storedColor: 0, sortOrder: areaPaletteArgb.length),
      areaPaletteArgb.first,
    );
    expect(
      resolveAreaColorArgb(
        storedColor: 0,
        sortOrder: areaPaletteArgb.length * 3 + 2,
      ),
      areaPaletteArgb[2],
    );
  });

  test('负数排序不越界', () {
    expect(
      resolveAreaColorArgb(storedColor: 0, sortOrder: -1),
      areaPaletteArgb.first,
    );
  });

  test('已设置的颜色原样返回，包括纯黑', () {
    expect(
      resolveAreaColorArgb(storedColor: 0xff123456, sortOrder: 2),
      0xff123456,
    );
    // 纯黑是"用户选过"，与"未设置"（0）必须可区分：否则选了黑色会被当成没选。
    expect(
      resolveAreaColorArgb(storedColor: 0xff000000, sortOrder: 0),
      0xff000000,
    );
    expect(hasCustomAreaColor(0xff000000), isTrue);
    expect(hasCustomAreaColor(0), isFalse);
  });

  test('色板本身至少有五个互不相同的低饱和色（对应五个默认领域）', () {
    expect(areaPaletteArgb.length, greaterThanOrEqualTo(5));
    expect(areaPaletteArgb.toSet().length, areaPaletteArgb.length);
  });
}
