// RFC 8785 规范化（UPD-006 的字节层）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/infrastructure/update/json_canonicalizer.dart';

void main() {
  group('对象键排序', () {
    test('按 UTF-16 码元升序，且没有空白', () {
      expect(canonicalizeJson({'b': 1, 'a': 2}), '{"a":2,"b":1}');
      expect(
        canonicalizeJson({
          'a': {'z': 1, 'y': 2},
        }),
        '{"a":{"y":2,"z":1}}',
      );
    });

    test('非 ASCII 键按码元顺序而不是按字节', () {
      // 'a' (0x61) 在 '€' (0x20AC) 之前。
      expect(canonicalizeJson({'€': 1, 'a': 2}), '{"a":2,"€":1}');
    });

    test('数组保持原顺序', () {
      expect(canonicalizeJson([3, 1, 2]), '[3,1,2]');
    });
  });

  group('数字（ECMAScript 最短往返）', () {
    test('整数与整数值 double 的写法', () {
      expect(canonicalJsonNumber(1), '1');
      expect(canonicalJsonNumber(1.0), '1');
      expect(canonicalJsonNumber(-0.0), '0');
      expect(canonicalJsonNumber(0.0), '0');
    });

    test('RFC 8785 §3.2.2 的数字向量', () {
      expect(canonicalJsonNumber(333333333.33333329), '333333333.3333333');
      expect(canonicalJsonNumber(1e30), '1e+30');
      expect(canonicalJsonNumber(4.50), '4.5');
      expect(canonicalJsonNumber(0.002), '0.002');
      expect(canonicalJsonNumber(2e-3), '0.002');
      expect(canonicalJsonNumber(1e-27), '1e-27');
      expect(canonicalJsonNumber(9007199254740992), '9007199254740992');
    });

    test('NaN 与 Infinity 不是合法 JSON', () {
      expect(() => canonicalJsonNumber(double.nan), throwsFormatException);
      expect(
        () => canonicalJsonNumber(double.infinity),
        throwsFormatException,
      );
    });
  });

  group('字符串最小转义', () {
    test('引号、反斜杠与控制字符', () {
      expect(canonicalJsonString('a"b'), r'"a\"b"');
      expect(canonicalJsonString(r'a\b'), r'"a\\b"');
      expect(canonicalJsonString('line\n'), r'"line\n"');
      expect(canonicalJsonString('\u000f'), r'"\u000f"');
      expect(canonicalJsonString('\u0001'), r'"\u0001"');
      expect(canonicalJsonString('\b\f\r\t'), r'"\b\f\r\t"');
    });

    test('非 ASCII 原样保留，不转义成 \\uXXXX', () {
      expect(canonicalJsonString('优计主义'), '"优计主义"');
      expect(canonicalJsonString('€\$'), '"€\$"');
    });
  });

  test('规范化的 UTF-8 字节可用于签名，且与字符串编码一致', () {
    const value = {'b': [1, 2.5], 'a': '优'};
    expect(
      canonicalizeJsonToUtf8(value),
      equals(utf8.encode(canonicalizeJson(value))),
    );
  });
}
