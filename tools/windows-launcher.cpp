#include <windows.h>

#include <string>
#include <vector>

// This launcher uses a static CRT, so no private DLL is needed beside it.
int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t* arguments, int show) {
  std::vector<wchar_t> buffer(32768);
  const DWORD size = GetModuleFileNameW(nullptr, buffer.data(),
                                      static_cast<DWORD>(buffer.size()));
  if (size == 0 || size >= buffer.size()) return ERROR_BAD_PATHNAME;
  const std::wstring executable(buffer.data(), size);
  const auto separator = executable.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return ERROR_BAD_PATHNAME;
  const auto directory = executable.substr(0, separator) + L"\\runtime";
  const auto application = directory + L"\\FolinqPDF.exe";
  std::wstring command = L"\"" + application + L"\"";
  if (arguments && *arguments) command += L" " + std::wstring(arguments);

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW;
  startup.wShowWindow = static_cast<WORD>(show);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(application.c_str(), command.data(), nullptr, nullptr,
                      FALSE, 0, nullptr, directory.c_str(), &startup, &process)) {
    const DWORD error = GetLastError();
    const auto message =
        L"\u65e0\u6cd5\u542f\u52a8 Folinq PDF\u3002\u8bf7\u5b8c\u6574\u89e3\u538b\u538b\u7f29\u5305\uff0c\u5e76\u4fdd\u7559 runtime \u6587\u4ef6\u5939\u3002\n\n" +
        application + L"\nWindows error: " + std::to_wstring(error);
    MessageBoxW(nullptr, message.c_str(), L"Folinq PDF", MB_OK | MB_ICONERROR);
    return static_cast<int>(error);
  }
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return 0;
}
