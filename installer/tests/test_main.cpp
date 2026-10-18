#include "test_support.h"

#include <windows.h>

#include <cstdio>
#include <iterator>

#include "native_shared/text.h"

namespace installer_tests {

int g_failures = 0;
std::wstring g_msix_path;
std::wstring g_certificate_path;
std::wstring g_second_certificate_path;
std::wstring g_helper_path;

std::vector<TestCase>& Registry() {
  static std::vector<TestCase> registry;
  return registry;
}

void RecordFailure(const char* file, int line, const std::string& message) {
  std::printf("FAIL %s:%d %s\n", file, line, message.c_str());
  ++g_failures;
}

std::string Utf8(const std::wstring& value) {
  return planner::native::Utf8FromWide(value);
}

}  // namespace installer_tests

namespace {

// 与测试可执行文件同目录的 helper：它由 `installer_tests` 的构建目标一起产出，
// 因而不论从哪个工作目录运行都能找到。找不到时 IPC 用例会报失败而不是崩溃。
std::wstring DefaultHelperPath() {
  wchar_t module[MAX_PATH * 2]{};
  const DWORD length = GetModuleFileNameW(nullptr, module,
                                          static_cast<DWORD>(std::size(module)));
  if (length == 0 || length >= std::size(module)) return {};
  std::wstring path(module, length);
  const size_t separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return {};
  return path.substr(0, separator + 1) + L"elevation_test_helper.exe";
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  SetConsoleOutputCP(CP_UTF8);
  for (int index = 1; index < argc; ++index) {
    const std::wstring argument = argv[index];
    if (argument == L"--msix" && index + 1 < argc) {
      installer_tests::g_msix_path = argv[++index];
    } else if (argument == L"--certificate" && index + 1 < argc) {
      installer_tests::g_certificate_path = argv[++index];
    } else if (argument == L"--second-certificate" && index + 1 < argc) {
      installer_tests::g_second_certificate_path = argv[++index];
    } else if (argument == L"--helper" && index + 1 < argc) {
      installer_tests::g_helper_path = argv[++index];
    }
  }
  if (installer_tests::g_helper_path.empty()) {
    installer_tests::g_helper_path = DefaultHelperPath();
  }

  int executed = 0;
  for (const auto& test : installer_tests::Registry()) {
    const int before = installer_tests::g_failures;
    try {
      test.function();
    } catch (...) {
      installer_tests::RecordFailure(test.name, 0, "unhandled exception");
    }
    ++executed;
    if (installer_tests::g_failures == before) {
      std::printf("PASS %s\n", test.name);
    }
  }
  std::printf("%d tests, %d failures\n", executed, installer_tests::g_failures);
  return installer_tests::g_failures == 0 ? 0 : 1;
}
