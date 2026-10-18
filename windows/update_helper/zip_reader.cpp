#include "zip_reader.h"

#include <cstdint>
#include <fstream>
#include <vector>

namespace update_helper {
namespace {

std::uint16_t ReadU16(const std::vector<BYTE>& data, std::size_t offset) {
  if (offset + 2 > data.size()) return 0;
  return static_cast<std::uint16_t>(data[offset] | (data[offset + 1] << 8));
}

std::uint32_t ReadU32(const std::vector<BYTE>& data, std::size_t offset);

std::uint64_t ReadU64(const std::vector<BYTE>& data, std::size_t offset) {
  if (offset + 8 > data.size()) return 0;
  return static_cast<std::uint64_t>(ReadU32(data, offset)) |
         (static_cast<std::uint64_t>(ReadU32(data, offset + 4)) << 32);
}

std::uint32_t ReadU32(const std::vector<BYTE>& data, std::size_t offset) {
  if (offset + 4 > data.size()) return 0;
  return static_cast<std::uint32_t>(
      data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) |
      (data[offset + 3] << 24));
}

bool LoadFile(const std::wstring& path, std::vector<BYTE>& data) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) return false;
  stream.seekg(0, std::ios::end);
  const auto size = stream.tellg();
  if (size <= 0) return false;
  stream.seekg(0, std::ios::beg);
  data.resize(static_cast<std::size_t>(size));
  stream.read(reinterpret_cast<char*>(data.data()), size);
  return stream.good();
}

// ── 最小 DEFLATE 解码器（RFC 1951）─────────────────────────────────────────
//
// Windows.Storage.Compression 只提供 MSZIP/Xpress/LZMS，没有 zip 使用的 raw deflate；
// 为了不依赖 AppxPackaging，这里实现标准的固定/动态 Huffman 与 stored 块。
struct BitReader {
  const BYTE* data;
  std::size_t size;
  std::size_t position = 0;
  std::uint32_t buffer = 0;
  int bits = 0;
  bool failed = false;

  int Read(int count) {
    while (bits < count) {
      if (position >= size) {
        failed = true;
        return 0;
      }
      buffer |= static_cast<std::uint32_t>(data[position++]) << bits;
      bits += 8;
    }
    const int value = static_cast<int>(buffer & ((1u << count) - 1));
    buffer >>= count;
    bits -= count;
    return value;
  }

  void AlignToByte() {
    buffer = 0;
    bits = 0;
  }
};

struct Huffman {
  int counts[16]{};
  std::vector<int> symbols;

  bool Build(const std::vector<int>& lengths) {
    for (int i = 0; i < 16; ++i) counts[i] = 0;
    for (int length : lengths) {
      if (length < 0 || length > 15) return false;
      ++counts[length];
    }
    counts[0] = 0;
    int left = 1;
    for (int length = 1; length <= 15; ++length) {
      left <<= 1;
      left -= counts[length];
      if (left < 0) return false;
    }
    int offsets[16]{};
    offsets[1] = 0;
    for (int length = 1; length < 15; ++length) {
      offsets[length + 1] = offsets[length] + counts[length];
    }
    symbols.assign(lengths.size(), 0);
    for (std::size_t index = 0; index < lengths.size(); ++index) {
      if (lengths[index] != 0) {
        symbols[offsets[lengths[index]]++] = static_cast<int>(index);
      }
    }
    return true;
  }

  int Decode(BitReader& reader) const {
    int code = 0;
    int first = 0;
    int index = 0;
    for (int length = 1; length <= 15; ++length) {
      code |= reader.Read(1);
      if (reader.failed) return -1;
      const int count = counts[length];
      if (code - first < count) return symbols[index + (code - first)];
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    return -1;
  }
};

bool InflateRaw(const std::vector<BYTE>& input, std::size_t expected_size,
                std::vector<BYTE>& output) {
  static const int length_base[29] = {
      3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23, 27,
      31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
  static const int length_extra[29] = {
      0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
      2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
  static const int distance_base[30] = {
      1,    2,    3,    4,    5,    7,     9,     13,    17,  25,
      33,   49,   65,   97,   129,  193,   257,   385,   513, 769,
      1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
  static const int distance_extra[30] = {
      0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
      6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

  BitReader reader{input.data(), input.size()};
  output.clear();
  output.reserve(expected_size == 0 ? 4096 : expected_size);

  bool final_block = false;
  while (!final_block) {
    if (reader.failed) return false;
    final_block = reader.Read(1) == 1;
    const int type = reader.Read(2);
    if (reader.failed || type == 3) return false;

    if (type == 0) {
      reader.AlignToByte();
      if (reader.position + 4 > reader.size) return false;
      const int length = input[reader.position] | (input[reader.position + 1] << 8);
      const int complement =
          input[reader.position + 2] | (input[reader.position + 3] << 8);
      reader.position += 4;
      if ((length ^ 0xFFFF) != complement) return false;
      if (reader.position + static_cast<std::size_t>(length) > reader.size) {
        return false;
      }
      output.insert(output.end(),
                    input.begin() + static_cast<std::ptrdiff_t>(reader.position),
                    input.begin() + static_cast<std::ptrdiff_t>(
                                        reader.position + length));
      reader.position += length;
      continue;
    }

    Huffman literal;
    Huffman distance;
    if (type == 1) {
      std::vector<int> literal_lengths(288, 8);
      for (int i = 144; i <= 255; ++i) literal_lengths[i] = 9;
      for (int i = 256; i <= 279; ++i) literal_lengths[i] = 7;
      for (int i = 280; i <= 287; ++i) literal_lengths[i] = 8;
      std::vector<int> distance_lengths(32, 5);
      if (!literal.Build(literal_lengths) || !distance.Build(distance_lengths)) {
        return false;
      }
    } else {
      const int literal_count = reader.Read(5) + 257;
      const int distance_count = reader.Read(5) + 1;
      const int code_length_count = reader.Read(4) + 4;
      static const int order[19] = {16, 17, 18, 0, 8,  7, 9,  6, 10, 5,
                                    11, 4,  12, 3, 13, 2, 14, 1, 15};
      std::vector<int> code_lengths(19, 0);
      for (int i = 0; i < code_length_count; ++i) {
        code_lengths[order[i]] = reader.Read(3);
      }
      Huffman code_length_code;
      if (!code_length_code.Build(code_lengths)) return false;
      std::vector<int> lengths;
      lengths.reserve(literal_count + distance_count);
      while (static_cast<int>(lengths.size()) <
             literal_count + distance_count) {
        const int symbol = code_length_code.Decode(reader);
        if (symbol < 0) return false;
        if (symbol < 16) {
          lengths.push_back(symbol);
        } else if (symbol == 16) {
          if (lengths.empty()) return false;
          const int repeat = reader.Read(2) + 3;
          const int previous = lengths.back();
          lengths.insert(lengths.end(), repeat, previous);
        } else if (symbol == 17) {
          lengths.insert(lengths.end(), reader.Read(3) + 3, 0);
        } else {
          lengths.insert(lengths.end(), reader.Read(7) + 11, 0);
        }
      }
      std::vector<int> literal_lengths(lengths.begin(),
                                       lengths.begin() + literal_count);
      std::vector<int> distance_lengths(lengths.begin() + literal_count,
                                        lengths.end());
      if (!literal.Build(literal_lengths) || !distance.Build(distance_lengths)) {
        return false;
      }
    }

    while (true) {
      const int symbol = literal.Decode(reader);
      if (symbol < 0) return false;
      if (symbol < 256) {
        output.push_back(static_cast<BYTE>(symbol));
      } else if (symbol == 256) {
        break;
      } else {
        const int length_index = symbol - 257;
        if (length_index >= 29) return false;
        const int length =
            length_base[length_index] + reader.Read(length_extra[length_index]);
        const int distance_symbol = distance.Decode(reader);
        if (distance_symbol < 0 || distance_symbol >= 30) return false;
        const int distance = distance_base[distance_symbol] +
                             reader.Read(distance_extra[distance_symbol]);
        if (reader.failed || distance <= 0 ||
            static_cast<std::size_t>(distance) > output.size()) {
          return false;
        }
        for (int i = 0; i < length; ++i) {
          output.push_back(output[output.size() - distance]);
        }
      }
      if (expected_size != 0 && output.size() > expected_size) return false;
      if (output.size() > 64 * 1024 * 1024) return false;  // 防御性上限
    }
  }
  if (expected_size != 0 && output.size() != expected_size) return false;
  return !reader.failed;
}

}  // namespace

bool ReadZipEntry(const std::wstring& path, const std::string& entry_name,
                  std::vector<BYTE>& out) {
  std::vector<BYTE> data;
  if (!LoadFile(path, data)) return false;

  const std::size_t search_start = data.size() > 65557 ? data.size() - 65557 : 0;
  std::size_t eocd = std::size_t(-1);
  for (std::size_t i = data.size() - 4; i + 4 >= 4 && i >= search_start; --i) {
    if (ReadU32(data, i) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd == std::size_t(-1)) return false;

  std::uint64_t count = ReadU16(data, eocd + 10);
  std::uint64_t directory_offset = ReadU32(data, eocd + 16);
  // MSIX 常被写成 ZIP64：EOCD 里的数量/偏移是 0xFFFF/0xFFFFFFFF，真实值在 ZIP64 记录里。
  if (eocd >= 20 && ReadU32(data, eocd - 20) == 0x07064b50) {
    const std::uint64_t zip64_offset = ReadU64(data, eocd - 12);
    if (zip64_offset + 56 <= data.size() &&
        ReadU32(data, static_cast<std::size_t>(zip64_offset)) == 0x06064b50) {
      count = ReadU64(data, static_cast<std::size_t>(zip64_offset) + 32);
      directory_offset =
          ReadU64(data, static_cast<std::size_t>(zip64_offset) + 48);
    }
  }
  std::size_t cursor = static_cast<std::size_t>(directory_offset);
  for (std::uint64_t index = 0; index < count; ++index) {
    if (ReadU32(data, cursor) != 0x02014b50) return false;
    const std::uint16_t method = ReadU16(data, cursor + 10);
    std::uint64_t compressed_size = ReadU32(data, cursor + 20);
    std::uint64_t uncompressed_size = ReadU32(data, cursor + 24);
    const std::uint16_t name_length = ReadU16(data, cursor + 28);
    const std::uint16_t extra_length = ReadU16(data, cursor + 30);
    const std::uint16_t comment_length = ReadU16(data, cursor + 32);
    std::uint64_t local_offset = ReadU32(data, cursor + 42);
    const std::size_t name_start = cursor + 46;
    if (name_start + name_length > data.size()) return false;
    // ZIP64 扩展字段（0x0001）：按 ZIP 规范顺序补齐 64 位大小与本地头偏移。
    if (compressed_size == 0xFFFFFFFF || uncompressed_size == 0xFFFFFFFF ||
        local_offset == 0xFFFFFFFF) {
      std::size_t extra = name_start + name_length;
      const std::size_t extra_end = extra + extra_length;
      while (extra + 4 <= extra_end && extra_end <= data.size()) {
        const std::uint16_t id = ReadU16(data, extra);
        const std::uint16_t length = ReadU16(data, extra + 2);
        std::size_t value = extra + 4;
        const std::size_t value_end = value + length;
        if (value_end > extra_end) break;
        if (id == 0x0001) {
          if (uncompressed_size == 0xFFFFFFFF && value + 8 <= value_end) {
            uncompressed_size = ReadU64(data, value);
            value += 8;
          }
          if (compressed_size == 0xFFFFFFFF && value + 8 <= value_end) {
            compressed_size = ReadU64(data, value);
            value += 8;
          }
          if (local_offset == 0xFFFFFFFF && value + 8 <= value_end) {
            local_offset = ReadU64(data, value);
          }
          break;
        }
        extra = value_end;
      }
    }
    const std::string name(
        reinterpret_cast<const char*>(data.data() + name_start), name_length);
    if (name == entry_name) {
      const std::size_t local = static_cast<std::size_t>(local_offset);
      if (ReadU32(data, local) != 0x04034b50) return false;
      const std::uint16_t local_name_length = ReadU16(data, local + 26);
      const std::uint16_t local_extra_length = ReadU16(data, local + 28);
      const std::size_t data_start =
          local + 30 + local_name_length + local_extra_length;
      if (data_start + static_cast<std::size_t>(compressed_size) >
          data.size()) {
        return false;
      }
      std::vector<BYTE> compressed(
          data.begin() + static_cast<std::ptrdiff_t>(data_start),
          data.begin() +
              static_cast<std::ptrdiff_t>(data_start + compressed_size));
      if (method == 0) {
        out = std::move(compressed);
        return true;
      }
      if (method == 8) {
        return InflateRaw(compressed, static_cast<std::size_t>(uncompressed_size),
                          out);
      }
      return false;
    }
    cursor = name_start + name_length + extra_length + comment_length;
  }
  return false;
}

}  // namespace update_helper
