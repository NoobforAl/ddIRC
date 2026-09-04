#include "single_instance.h"

#include <wchar.h>

#include <string>

namespace {

// The window class every Flutter Windows app uses, ours included — which is
// exactly why matching on it alone is not enough. Another Flutter application
// running at the same time has a window of this class too, and raising *that*
// because the user launched ddIRC would be a considerably worse bug than the
// one being fixed.
constexpr const wchar_t kFlutterWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

struct SearchState {
  std::wstring executable;
  HWND found = nullptr;
};

// This process's own executable path, as the yardstick for "is that window
// one of ours".
//
// The path rather than the title: the title is set from Dart once the app is
// up, so a copy still starting has a different one, and a search that depended
// on it would hand the user a second window precisely during the seconds when
// double-launching is most likely.
std::wstring ExecutablePath() {
  wchar_t path[MAX_PATH] = {L'\0'};
  DWORD length = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (length == 0 || length == MAX_PATH) {
    return std::wstring();
  }
  return std::wstring(path, length);
}

std::wstring PathOfProcess(DWORD process_id) {
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                 process_id);
  if (process == nullptr) {
    return std::wstring();
  }
  wchar_t path[MAX_PATH] = {L'\0'};
  DWORD size = MAX_PATH;
  const bool ok = ::QueryFullProcessImageNameW(process, 0, path, &size) != 0;
  ::CloseHandle(process);
  return ok ? std::wstring(path, size) : std::wstring();
}

BOOL CALLBACK FindOurWindow(HWND window, LPARAM parameter) {
  auto* state = reinterpret_cast<SearchState*>(parameter);

  wchar_t class_name[64] = {L'\0'};
  if (::GetClassNameW(window, class_name, 64) == 0) {
    return TRUE;
  }
  if (::wcscmp(class_name, kFlutterWindowClass) != 0) {
    return TRUE;
  }

  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id == 0 || process_id == ::GetCurrentProcessId()) {
    return TRUE;
  }

  if (::_wcsicmp(PathOfProcess(process_id).c_str(),
                 state->executable.c_str()) != 0) {
    return TRUE;
  }

  state->found = window;
  return FALSE;
}

}  // namespace

SingleInstance::SingleInstance(const wchar_t* name) {
  // "Local\" rather than "Global\": the name is scoped to this logon session,
  // so two people signed in at once each get their own ddIRC. A global name
  // would let the first of them lock the other out of an application they had
  // never launched.
  mutex_ = ::CreateMutexW(nullptr, TRUE, name);
  already_running_ = mutex_ != nullptr &&
                     ::GetLastError() == ERROR_ALREADY_EXISTS;
}

SingleInstance::~SingleInstance() {
  if (mutex_ != nullptr) {
    ::CloseHandle(mutex_);
  }
}

bool SingleInstance::RaiseExistingWindow() {
  SearchState state;
  state.executable = ExecutablePath();
  if (state.executable.empty()) {
    return false;
  }

  ::EnumWindows(FindOurWindow, reinterpret_cast<LPARAM>(&state));
  if (state.found == nullptr) {
    return false;
  }

  // Three separate conditions, and the window can be in all of them at once:
  // hidden to the tray, minimised, and behind something. Unhiding a window
  // that is not hidden and restoring one that is not minimised both cost
  // nothing, so each is simply done rather than tested for.
  if (::IsWindowVisible(state.found) == 0) {
    ::ShowWindow(state.found, SW_SHOW);
  }
  if (::IsIconic(state.found) != 0) {
    ::ShowWindow(state.found, SW_RESTORE);
  }
  // Allowed because this process is the one the user just launched, and so is
  // the foreground process — Windows lets it hand the foreground on, which is
  // the whole reason this is done here rather than asked of the other copy.
  ::SetForegroundWindow(state.found);
  return true;
}
