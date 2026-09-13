#include "pionbridge_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <filesystem>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <thread>

namespace pion_bridge {

namespace {

// Returns the directory containing the running executable.
std::wstring GetExeDir() {
  wchar_t path[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring p(path);
  auto pos = p.rfind(L'\\');
  return pos != std::wstring::npos ? p.substr(0, pos) : p;
}

// Returns path to the bundled pionbridge.exe (next to the host executable).
std::wstring GetBinaryPath() {
  return GetExeDir() + L"\\pionbridge.exe";
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  int sz = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                               static_cast<int>(wide.size()),
                               nullptr, 0, nullptr, nullptr);
  std::string out(sz, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      out.data(), sz, nullptr, nullptr);
  return out;
}

// Read one '\n'-terminated line from a HANDLE, timing out after timeout_ms.
std::string ReadLineTimeout(HANDLE h, DWORD timeout_ms) {
  std::string line;
  char ch;
  DWORD read_bytes;
  auto deadline = GetTickCount64() + timeout_ms;

  while (GetTickCount64() < deadline) {
    // Peek to see if data is available
    DWORD available = 0;
    if (!PeekNamedPipe(h, nullptr, 0, nullptr, &available, nullptr) ||
        available == 0) {
      Sleep(20);
      continue;
    }
    if (!ReadFile(h, &ch, 1, &read_bytes, nullptr) || read_bytes == 0) break;
    if (ch == '\n') break;
    if (ch != '\r') line += ch;
  }
  return line;
}

}  // namespace

// static
void PionBridgePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "io.pion_bridge.bridge",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<PionBridgePlugin>();
  channel->SetMethodCallHandler(
      [plugin_ptr = plugin.get()](const auto& call, auto result) {
        plugin_ptr->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

PionBridgePlugin::PionBridgePlugin() = default;

PionBridgePlugin::~PionBridgePlugin() {
  // Note: a detached startup thread may still be running here. The mutex keeps
  // handle access safe, but the thread also captures `this`; callers must not
  // destroy the plugin while a startServer is genuinely in flight.
  std::lock_guard<std::mutex> lock(process_mutex_);
  if (process_handle_ != INVALID_HANDLE_VALUE) {
    TerminateProcess(process_handle_, 0);
    CloseHandle(process_handle_);
    process_handle_ = INVALID_HANDLE_VALUE;
  }
  if (stdout_read_ != INVALID_HANDLE_VALUE) {
    CloseHandle(stdout_read_);
    stdout_read_ = INVALID_HANDLE_VALUE;
  }
  if (stdin_write_ != INVALID_HANDLE_VALUE) {
    CloseHandle(stdin_write_);
    stdin_write_ = INVALID_HANDLE_VALUE;
  }
}

void PionBridgePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "startServer") {
    StartServer(std::move(result));
  } else if (method_call.method_name() == "stopServer") {
    StopServer(std::move(result));
  } else {
    result->NotImplemented();
  }
}

void PionBridgePlugin::StartServer(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Kill any existing server
  {
    std::lock_guard<std::mutex> lock(process_mutex_);
    if (process_handle_ != INVALID_HANDLE_VALUE) {
      TerminateProcess(process_handle_, 0);
      CloseHandle(process_handle_);
      process_handle_ = INVALID_HANDLE_VALUE;
    }
    if (stdout_read_ != INVALID_HANDLE_VALUE) {
      CloseHandle(stdout_read_);
      stdout_read_ = INVALID_HANDLE_VALUE;
    }
    if (stdin_write_ != INVALID_HANDLE_VALUE) {
      CloseHandle(stdin_write_);
      stdin_write_ = INVALID_HANDLE_VALUE;
    }
  }

  std::wstring binary_path = GetBinaryPath();
  if (!std::filesystem::exists(binary_path)) {
    result->Error("BINARY_NOT_FOUND",
                  "pionbridge.exe not found at: " +
                      WideToUtf8(binary_path));
    return;
  }

  // Create anonymous pipe for stdout
  HANDLE stdout_write = INVALID_HANDLE_VALUE;
  SECURITY_ATTRIBUTES sa = {};
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;
  if (!CreatePipe(&stdout_read_, &stdout_write, &sa, 0)) {
    result->Error("SERVER_START_FAILED", "CreatePipe failed");
    return;
  }
  // Make read end non-inheritable
  SetHandleInformation(stdout_read_, HANDLE_FLAG_INHERIT, 0);

  // Stdin pipe the child reads until EOF: we keep the write end, so it closes
  // when this process exits or dies.
  HANDLE stdin_read = INVALID_HANDLE_VALUE;
  if (!CreatePipe(&stdin_read, &stdin_write_, &sa, 0)) {
    CloseHandle(stdout_read_);
    stdout_read_ = INVALID_HANDLE_VALUE;
    CloseHandle(stdout_write);
    result->Error("SERVER_START_FAILED", "CreatePipe (stdin) failed");
    return;
  }
  // Make write end non-inheritable
  SetHandleInformation(stdin_write_, HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;
  si.hStdOutput = stdout_write;
  si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
  si.hStdInput = stdin_read;

  PROCESS_INFORMATION pi = {};
  std::wstring cmd = L"\"" + binary_path + L"\"";
  BOOL ok = CreateProcessW(
      nullptr, cmd.data(), nullptr, nullptr,
      TRUE,   // inherit handles
      CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);

  CloseHandle(stdout_write);  // child has its own copy
  CloseHandle(stdin_read);    // child has its own copy

  if (!ok) {
    std::lock_guard<std::mutex> lock(process_mutex_);
    CloseHandle(stdout_read_);
    stdout_read_ = INVALID_HANDLE_VALUE;
    CloseHandle(stdin_write_);
    stdin_write_ = INVALID_HANDLE_VALUE;
    result->Error("SERVER_START_FAILED",
                  "CreateProcess failed: " + std::to_string(GetLastError()));
    return;
  }

  CloseHandle(pi.hThread);
  HANDLE my_process = pi.hProcess;
  HANDLE h;
  {
    std::lock_guard<std::mutex> lock(process_mutex_);
    process_handle_ = my_process;
    h = stdout_read_;
  }

  // Read startup JSON with 10s timeout on a background thread
  // (ReadFile can block; we use PeekNamedPipe polling in ReadLineTimeout)
  auto shared_result =
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
          std::move(result));

  std::thread([this, h, my_process, shared_result]() {
    std::string line = ReadLineTimeout(h, 10000);

    // Parse {"port":<int>,"token":"<str>"}
    int port = 0;
    std::string token;

    auto extract_int = [&](const std::string& key) -> int {
      auto pos = line.find("\"" + key + "\"");
      if (pos == std::string::npos) return 0;
      pos = line.find(':', pos);
      if (pos == std::string::npos) return 0;
      try { return std::stoi(line.substr(pos + 1)); } catch (...) { return 0; }
    };
    auto extract_str = [&](const std::string& key) -> std::string {
      auto pos = line.find("\"" + key + "\"");
      if (pos == std::string::npos) return "";
      pos = line.find('"', pos + key.size() + 2);
      if (pos == std::string::npos) return "";
      auto end = line.find('"', pos + 1);
      if (end == std::string::npos) return "";
      return line.substr(pos + 1, end - pos - 1);
    };

    port = extract_int("port");
    token = extract_str("token");

    if (port == 0 || token.empty()) {
      std::lock_guard<std::mutex> lock(process_mutex_);
      // Only tear down if this is still the process we launched — a newer
      // startServer may have already replaced it.
      if (process_handle_ == my_process &&
          process_handle_ != INVALID_HANDLE_VALUE) {
        TerminateProcess(process_handle_, 0);
        CloseHandle(process_handle_);
        process_handle_ = INVALID_HANDLE_VALUE;
      }
      shared_result->Error("SERVER_START_FAILED",
                           "Failed to parse startup JSON: " + line);
      return;
    }

    flutter::EncodableMap response;
    response[flutter::EncodableValue("port")] =
        flutter::EncodableValue(port);
    response[flutter::EncodableValue("token")] =
        flutter::EncodableValue(token);
    shared_result->Success(flutter::EncodableValue(response));
  }).detach();
}

void PionBridgePlugin::StopServer(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  {
    std::lock_guard<std::mutex> lock(process_mutex_);
    if (process_handle_ != INVALID_HANDLE_VALUE) {
      TerminateProcess(process_handle_, 0);
      CloseHandle(process_handle_);
      process_handle_ = INVALID_HANDLE_VALUE;
    }
    // Also release the stdout pipe read handle: StartServer teardown and the
    // destructor both close it, but a stopServer not followed by another
    // startServer would otherwise leak it until plugin destruction.
    if (stdout_read_ != INVALID_HANDLE_VALUE) {
      CloseHandle(stdout_read_);
      stdout_read_ = INVALID_HANDLE_VALUE;
    }
    if (stdin_write_ != INVALID_HANDLE_VALUE) {
      CloseHandle(stdin_write_);
      stdin_write_ = INVALID_HANDLE_VALUE;
    }
  }
  result->Success();
}

}  // namespace pion_bridge
