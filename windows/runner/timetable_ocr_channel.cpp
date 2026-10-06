#include "timetable_ocr_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodResult;
using winrt::Windows::Globalization::Language;
using winrt::Windows::Graphics::Imaging::BitmapAlphaMode;
using winrt::Windows::Graphics::Imaging::BitmapBounds;
using winrt::Windows::Graphics::Imaging::BitmapDecoder;
using winrt::Windows::Graphics::Imaging::BitmapPixelFormat;
using winrt::Windows::Graphics::Imaging::BitmapRotation;
using winrt::Windows::Graphics::Imaging::BitmapTransform;
using winrt::Windows::Graphics::Imaging::ColorManagementMode;
using winrt::Windows::Graphics::Imaging::ExifOrientationMode;
using winrt::Windows::Media::Ocr::OcrEngine;
using winrt::Windows::Storage::Streams::DataWriter;
using winrt::Windows::Storage::Streams::InMemoryRandomAccessStream;

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  const auto found = map.find(EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

std::optional<double> Number(const EncodableValue* value) {
  if (value == nullptr) return std::nullopt;
  if (const auto* number = std::get_if<double>(value)) return *number;
  if (const auto* number = std::get_if<int32_t>(value)) {
    return static_cast<double>(*number);
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    return static_cast<double>(*number);
  }
  return std::nullopt;
}

std::optional<int32_t> Integer(const EncodableValue* value) {
  if (value == nullptr) return std::nullopt;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  if (const auto* number = std::get_if<int64_t>(value)) {
    return static_cast<int32_t>(*number);
  }
  return std::nullopt;
}

void Error(std::unique_ptr<MethodResult<EncodableValue>>& result,
           const std::string& code, const std::string& message) {
  result->Error(code, message);
}

BitmapRotation RotationFor(int32_t quarter_turns) {
  switch (quarter_turns) {
    case 1:
      return BitmapRotation::Clockwise90Degrees;
    case 2:
      return BitmapRotation::Clockwise180Degrees;
    case 3:
      return BitmapRotation::Clockwise270Degrees;
    default:
      return BitmapRotation::None;
  }
}

EncodableMap BoundsMap(const winrt::Windows::Foundation::Rect& bounds) {
  return {
      {EncodableValue("left"), EncodableValue(static_cast<double>(bounds.X))},
      {EncodableValue("top"), EncodableValue(static_cast<double>(bounds.Y))},
      {EncodableValue("width"),
       EncodableValue(static_cast<double>(bounds.Width))},
      {EncodableValue("height"),
       EncodableValue(static_cast<double>(bounds.Height))},
  };
}

winrt::fire_and_forget Recognize(
    std::string path, std::string language_tag, int32_t quarter_turns,
    std::optional<EncodableMap> crop,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  Language language{nullptr};
  try {
    language = Language(winrt::to_hstring(language_tag));
    if (!OcrEngine::IsLanguageSupported(language)) {
      Error(result, "language_unavailable",
            "The requested local OCR language is not installed.");
      co_return;
    }
  } catch (...) {
    Error(result, "language_unavailable",
          "The requested local OCR language is unavailable.");
    co_return;
  }

  winrt::Windows::Graphics::Imaging::SoftwareBitmap bitmap{nullptr};
  const char* decode_stage = "read_file";
  try {
    // File-selector already grants this desktop process a normal filesystem
    // path. Reopening it through StorageFile can still fail with E_ACCESSDENIED
    // in an unpackaged runner, so load the bytes with ordinary desktop file
    // I/O and give BitmapDecoder an in-memory WinRT stream.
    const std::filesystem::path file_path{winrt::to_hstring(path).c_str()};
    std::ifstream input(file_path, std::ios::binary | std::ios::ate);
    if (!input) {
      Error(result, "decode_failed", "stage=read_file unavailable");
      co_return;
    }
    const auto byte_count = input.tellg();
    if (byte_count <= 0) {
      Error(result, "decode_failed", "stage=read_file empty");
      co_return;
    }
    std::vector<uint8_t> bytes(static_cast<size_t>(byte_count));
    input.seekg(0, std::ios::beg);
    if (!input.read(reinterpret_cast<char*>(bytes.data()), byte_count)) {
      Error(result, "decode_failed", "stage=read_file incomplete");
      co_return;
    }

    decode_stage = "write_memory_stream";
    InMemoryRandomAccessStream stream;
    DataWriter writer(stream);
    writer.WriteBytes(bytes);
    co_await writer.StoreAsync();
    writer.DetachStream();
    stream.Seek(0);

    decode_stage = "create_decoder";
    const auto decoder = co_await BitmapDecoder::CreateAsync(stream);

    const uint32_t source_width = decoder.PixelWidth();
    const uint32_t source_height = decoder.PixelHeight();
    BitmapTransform transform;
    uint32_t crop_x = 0;
    uint32_t crop_y = 0;
    uint32_t crop_width = source_width;
    uint32_t crop_height = source_height;
    if (crop.has_value()) {
      const auto left = Number(Find(*crop, "left"));
      const auto top = Number(Find(*crop, "top"));
      const auto width = Number(Find(*crop, "width"));
      const auto height = Number(Find(*crop, "height"));
      if (!left || !top || !width || !height || *left < 0 || *top < 0 ||
          *width <= 0 || *height <= 0 || *left + *width > 1.0 ||
          *top + *height > 1.0) {
        Error(result, "decode_failed", "The crop rectangle is invalid.");
        co_return;
      }
      crop_x = static_cast<uint32_t>(*left * source_width);
      crop_y = static_cast<uint32_t>(*top * source_height);
      crop_width = std::max<uint32_t>(
          1, static_cast<uint32_t>(*width * source_width));
      crop_height = std::max<uint32_t>(
          1, static_cast<uint32_t>(*height * source_height));
      crop_width = std::min(crop_width, source_width - crop_x);
      crop_height = std::min(crop_height, source_height - crop_y);
    }
    transform.Bounds(
        BitmapBounds{crop_x, crop_y, crop_width, crop_height});
    transform.Rotation(RotationFor(quarter_turns));

    const uint32_t output_width = quarter_turns % 2 == 0 ? crop_width : crop_height;
    const uint32_t output_height = quarter_turns % 2 == 0 ? crop_height : crop_width;
    const uint32_t maximum = OcrEngine::MaxImageDimension();
    if (output_width > maximum || output_height > maximum) {
      Error(result, "image_too_large",
            "The selected image exceeds the local OCR size limit.");
      co_return;
    }

    decode_stage = "get_software_bitmap";
    bitmap = co_await decoder.GetSoftwareBitmapAsync(
        BitmapPixelFormat::Bgra8, BitmapAlphaMode::Premultiplied, transform,
        ExifOrientationMode::RespectExifOrientation,
        ColorManagementMode::ColorManageToSRgb);
  } catch (const winrt::hresult_error& error) {
    Error(result, "decode_failed",
          std::string("stage=") + decode_stage +
              " hresult=" +
              std::to_string(static_cast<int32_t>(error.code())));
    co_return;
  } catch (...) {
    Error(result, "decode_failed",
          std::string("stage=") + decode_stage + " native_error");
    co_return;
  }

  try {
    const auto engine = OcrEngine::TryCreateFromLanguage(language);
    if (!engine) {
      Error(result, "language_unavailable",
            "The requested local OCR language is unavailable.");
      co_return;
    }
    const auto recognized = co_await engine.RecognizeAsync(bitmap);
    EncodableList lines;
    for (const auto& line : recognized.Lines()) {
      EncodableList words;
      for (const auto& word : line.Words()) {
        words.emplace_back(EncodableMap{
            {EncodableValue("text"),
             EncodableValue(winrt::to_string(word.Text()))},
            {EncodableValue("bounds"), EncodableValue(BoundsMap(word.BoundingRect()))},
        });
      }
      lines.emplace_back(EncodableMap{
          {EncodableValue("text"),
           EncodableValue(winrt::to_string(line.Text()))},
          {EncodableValue("words"), EncodableValue(std::move(words))},
      });
    }

    EncodableValue angle;
    if (const auto text_angle = recognized.TextAngle()) {
      angle = EncodableValue(text_angle.Value());
    }
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("width"),
         EncodableValue(static_cast<int32_t>(bitmap.PixelWidth()))},
        {EncodableValue("height"),
         EncodableValue(static_cast<int32_t>(bitmap.PixelHeight()))},
        {EncodableValue("textAngle"), std::move(angle)},
        {EncodableValue("lines"), EncodableValue(std::move(lines))},
    }));
  } catch (...) {
    Error(result, "recognition_failed",
          "Local OCR could not recognize the selected image.");
  }
}

}  // namespace

void RegisterTimetableOcrChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "personal_planner/timetable_ocr",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const auto& call,
         std::unique_ptr<MethodResult<EncodableValue>> result) {
        if (call.method_name() != "recognize") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("decode_failed", "OCR arguments are invalid.");
          return;
        }
        const auto* path_value = Find(*arguments, "path");
        const auto* language_value = Find(*arguments, "languageTag");
        const auto* path = path_value == nullptr
                               ? nullptr
                               : std::get_if<std::string>(path_value);
        const auto* language = language_value == nullptr
                                   ? nullptr
                                   : std::get_if<std::string>(language_value);
        const auto turns = Integer(Find(*arguments, "quarterTurns"));
        if (path == nullptr || path->empty() || language == nullptr ||
            language->empty() || !turns || *turns < 0 || *turns > 3) {
          result->Error("decode_failed", "OCR arguments are invalid.");
          return;
        }

        std::optional<EncodableMap> crop;
        if (const auto* crop_value = Find(*arguments, "cropRect");
            crop_value != nullptr && !std::holds_alternative<std::monostate>(*crop_value)) {
          const auto* crop_map = std::get_if<EncodableMap>(crop_value);
          if (crop_map == nullptr) {
            result->Error("decode_failed", "OCR crop arguments are invalid.");
            return;
          }
          crop = *crop_map;
        }
        Recognize(*path, *language, *turns, std::move(crop),
                  std::move(result));
      });
}
