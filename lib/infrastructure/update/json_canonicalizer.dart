// RFC 8785 JSON Canonicalization Scheme（规格 §6.2 第 1 条）。
//
// 签名必须对**规范化后的字节**做，否则同一份逻辑内容可以有无数种序列化（键顺序、
// 空白、数字写法），签名就无法稳定复现。RFC 8785 把这些自由度固定成一条唯一形式：
//   · 对象键按 UTF-16 码元升序排列；
//   · 没有空白；
//   · 字符串使用 ECMAScript 的最小转义；
//   · 数字使用 ECMAScript `Number::toString` 的最短往返表示。
//
// **为什么自己实现而不是找一个包**：规范化是签名协议的一部分，它必须与发布流水线
// （`tool/update_pipeline.dart`）使用**同一份**规则。自己实现 + 用 RFC 8785 的公开向量
// 与 Dart 侧签名/验签互测，可以把"两边各自实现、规则悄悄不同"的风险压到最低。
import 'dart:convert';

/// 把已解码的 JSON 值规范化成字符串。
///
/// 只接受 `jsonDecode` 能产生的类型（`null`/`bool`/`num`/`String`/`List`/`Map`）。
/// 其他类型是调用方的错误，抛 [FormatException] 而不是"尽力序列化"。
String canonicalizeJson(Object? value) {
  final buffer = StringBuffer();
  _write(value, buffer);
  return buffer.toString();
}

/// 规范化并编码为 UTF-8 字节（签名/摘要的输入）。
List<int> canonicalizeJsonToUtf8(Object? value) =>
    utf8.encode(canonicalizeJson(value));

void _write(Object? value, StringBuffer out) {
  switch (value) {
    case null:
      out.write('null');
    case bool():
      out.write(value ? 'true' : 'false');
    case int():
      out.write(value.toString());
    case double():
      out.write(canonicalJsonNumber(value));
    case String():
      out.write(canonicalJsonString(value));
    case List():
      out.write('[');
      for (var i = 0; i < value.length; i++) {
        if (i > 0) out.write(',');
        _write(value[i], out);
      }
      out.write(']');
    case Map():
      // 键排序使用 **UTF-16 码元** 顺序：Dart 的 `String.compareTo` 就是逐码元比较，
      // 与 ECMAScript 的 `<` 对字符串的语义一致。
      final keys = value.keys.map((key) {
        if (key is! String) {
          throw const FormatException('JSON 对象的键必须是字符串');
        }
        return key;
      }).toList()..sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        out.write(canonicalJsonString(keys[i]));
        out.write(':');
        _write(value[keys[i]], out);
      }
      out.write('}');
    default:
      throw FormatException('无法规范化的类型：${value.runtimeType}');
  }
}

/// ECMAScript 数字的最短往返表示。
///
/// Dart 的 `double.toString()` 同样是"最短往返"表示，差异只体现在：
///   · 整数值的 double 会带 `.0`（ECMAScript 不带）；
///   · `-0.0` 在 ECMAScript 里是 `0`；
///   · 非有限值在 JSON 里不允许（这里直接拒绝，而不是写成 `NaN`）。
String canonicalJsonNumber(num value) {
  if (value is int) return value.toString();
  final doubleValue = value.toDouble();
  if (doubleValue.isNaN || doubleValue.isInfinite) {
    throw const FormatException('JSON 不支持 NaN/Infinity');
  }
  if (doubleValue == 0) return '0';
  var text = doubleValue.toString();
  if (text.endsWith('.0')) {
    text = text.substring(0, text.length - 2);
  }
  return text;
}

/// 字符串的 ECMAScript 最小转义写法。
///
/// 只有以下字符需要转义：`"`、`\`、以及 U+0000–U+001F 控制字符。非 ASCII 字符
/// **保留原样**（RFC 8785 要求输出 UTF-8，而不是 `\uXXXX` 形式）；`/` 不转义。
String canonicalJsonString(String value) {
  final buffer = StringBuffer('"');
  for (final unit in value.codeUnits) {
    switch (unit) {
      case 0x22:
        buffer.write(r'\"');
      case 0x5C:
        buffer.write(r'\\');
      case 0x08:
        buffer.write(r'\b');
      case 0x09:
        buffer.write(r'\t');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0C:
        buffer.write(r'\f');
      case 0x0D:
        buffer.write(r'\r');
      default:
        if (unit < 0x20) {
          buffer.write(r'\u');
          buffer.write(unit.toRadixString(16).padLeft(4, '0'));
        } else {
          buffer.writeCharCode(unit);
        }
    }
  }
  buffer.write('"');
  return buffer.toString();
}
