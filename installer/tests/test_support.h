// 极简测试框架：不引入外部依赖，发布机与 CI 上都能直接跑。
#pragma once

#include <string>
#include <vector>

namespace installer_tests {

using TestFunction = void (*)();

struct TestCase {
  const char* name;
  TestFunction function;
};

std::vector<TestCase>& Registry();

struct Registration {
  Registration(const char* name, TestFunction function) {
    Registry().push_back({name, function});
  }
};

void RecordFailure(const char* file, int line, const std::string& message);
std::string Utf8(const std::wstring& value);

extern int g_failures;

// 由命令行提供的真实产物路径；为空时相关用例跳过。
extern std::wstring g_msix_path;
extern std::wstring g_certificate_path;
extern std::wstring g_second_certificate_path;

}  // namespace installer_tests

#define TEST(name)                                                     \
  static void name();                                                  \
  static installer_tests::Registration name##_registration(#name, name); \
  static void name()

#define EXPECT_TRUE(condition)                                             \
  do {                                                                     \
    if (!(condition)) {                                                    \
      installer_tests::RecordFailure(                                      \
          __FILE__, __LINE__,                                              \
          std::string("expected true: ") + #condition);                    \
    }                                                                      \
  } while (false)

#define EXPECT_FALSE(condition)                                            \
  do {                                                                     \
    if ((condition)) {                                                     \
      installer_tests::RecordFailure(                                      \
          __FILE__, __LINE__,                                              \
          std::string("expected false: ") + #condition);                   \
    }                                                                      \
  } while (false)

#define EXPECT_INT_EQ(expected, actual)                                    \
  do {                                                                     \
    const auto expected_value = (expected);                                \
    const auto actual_value = (actual);                                    \
    if (expected_value != actual_value) {                                  \
      installer_tests::RecordFailure(                                      \
          __FILE__, __LINE__,                                              \
          std::string(#expected " != " #actual) + " (" +                   \
              std::to_string(static_cast<long long>(expected_value)) +     \
              " vs " +                                                     \
              std::to_string(static_cast<long long>(actual_value)) + ")"); \
    }                                                                      \
  } while (false)

#define EXPECT_WSTRING_EQ(expected, actual)                                \
  do {                                                                     \
    const std::wstring expected_value = (expected);                        \
    const std::wstring actual_value = (actual);                            \
    if (expected_value != actual_value) {                                  \
      installer_tests::RecordFailure(                                      \
          __FILE__, __LINE__,                                              \
          std::string(#expected " != " #actual) + " (" +                   \
              installer_tests::Utf8(expected_value) + " vs " +             \
              installer_tests::Utf8(actual_value) + ")");                  \
    }                                                                      \
  } while (false)
