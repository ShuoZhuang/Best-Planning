const List<int> areaPaletteArgb = <int>[
  0xff2f86ff,
  0xff53c7a5,
  0xfff2b35d,
  0xfff06f7a,
  0xffb391d3,
  0xff5ec8e5,
  0xff7f92b2,
  0xffa8b86f,
];

const List<String> areaPaletteNames = <String>[
  '蓝色',
  '青绿色',
  '琥珀色',
  '珊瑚色',
  '紫色',
  '青蓝色',
  '灰蓝色',
  '橄榄色',
];

const int defaultProtectedTimeArgb = 0xff5ec8e5;
const int defaultUnassignedTaskArgb = 0xff7f92b2;
const int defaultUnassignedFixedArgb = 0xffa8b86f;

int resolveAreaColorArgb(int storedColor, int sortOrder) {
  if (storedColor != 0) return storedColor;
  final index = sortOrder < 0 ? 0 : sortOrder % areaPaletteArgb.length;
  return areaPaletteArgb[index];
}

bool hasCustomAreaColor(int storedColor) => storedColor != 0;

bool isOpaqueArgb(int value) => value >= 0xff000000 && value <= 0xffffffff;
