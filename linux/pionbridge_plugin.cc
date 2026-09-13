#include "include/pion_bridge/pionbridge_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <chrono>

#define PIONBRIDGE_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), pionbridge_plugin_get_type(), \
                               PionbridgePlugin))

struct _PionbridgePlugin {
  GObject parent_instance;
  FlMethodChannel* channel;
  GPid server_pid;
  gint stdout_fd;
  // Write end of the child's stdin. Never written; held so the kernel closes
  // it when this process dies for any reason (exit(), crash, SIGKILL), which
  // is the Go server's cue to exit (see go/main.go). dispose() alone does not
  // run on those paths, so without this the server outlives the app.
  gint stdin_fd;
};

// Guards server_pid/stdout_fd/stdin_fd: the start worker runs on a detached thread
// while dispose/stopServer/a second startServer run on the GTK thread, and
// unsynchronized access could kill the wrong pid or leak an overwritten one.
// Static storage (zero-init) so no init/clear lifecycle is needed.
static std::mutex server_mutex;

// Reaps the child once it exits. Children are spawned with
// G_SPAWN_DO_NOT_REAP_CHILD and g_spawn_close_pid() does NOT waitpid() on
// POSIX, so without this watch every killed/exited server would accumulate
// as a <defunct> zombie for the host process lifetime (one per hot restart).
// The watch source itself collects the exit status (reaping the process);
// g_spawn_close_pid here is for portability hygiene only.
static void child_exited_cb(GPid pid, gint status, gpointer user_data) {
  g_spawn_close_pid(pid);
}

G_DEFINE_TYPE(PionbridgePlugin, pionbridge_plugin, g_object_get_type())

static void pionbridge_plugin_dispose(GObject* object) {
  PionbridgePlugin* self = PIONBRIDGE_PLUGIN(object);
  {
    std::lock_guard<std::mutex> lock(server_mutex);
    if (self->server_pid != 0) {
      // The child watch added at spawn time reaps it after the kill.
      kill(self->server_pid, SIGTERM);
      self->server_pid = 0;
    }
    if (self->stdout_fd >= 0) {
      close(self->stdout_fd);
      self->stdout_fd = -1;
    }
    if (self->stdin_fd >= 0) {
      close(self->stdin_fd);
      self->stdin_fd = -1;
    }
  }
  g_clear_object(&self->channel);
  G_OBJECT_CLASS(pionbridge_plugin_parent_class)->dispose(object);
}

static void pionbridge_plugin_class_init(PionbridgePluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = pionbridge_plugin_dispose;
}

static void pionbridge_plugin_init(PionbridgePlugin* self) {
  self->server_pid = 0;
  self->stdout_fd = -1;
  self->stdin_fd = -1;
}

// Returns the path to the bundled pionbridge binary.
// On Linux the binary lives next to the app executable in lib/.
static std::string get_binary_path() {
  // Resolve /proc/self/exe to find the app directory
  char exe_path[4096] = {};
  ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
  if (len < 0) return "";
  exe_path[len] = '\0';

  // Strip the executable filename to get the app dir
  std::string dir(exe_path);
  auto pos = dir.rfind('/');
  if (pos != std::string::npos) dir = dir.substr(0, pos);

  return dir + "/lib/pionbridge";
}

// Read one line from a file descriptor with a timeout (seconds).
// Returns the line (without newline) or empty string on timeout/error.
static std::string read_line_timeout(int fd, int timeout_secs) {
  std::string line;
  char ch;
  auto deadline = std::chrono::steady_clock::now() +
                  std::chrono::seconds(timeout_secs);

  // Set non-blocking
  int flags = fcntl(fd, F_GETFL, 0);
  fcntl(fd, F_SETFL, flags | O_NONBLOCK);

  while (std::chrono::steady_clock::now() < deadline) {
    ssize_t n = read(fd, &ch, 1);
    if (n == 1) {
      if (ch == '\n') break;
      line += ch;
    } else if (n == 0) {
      break;  // EOF
    } else {
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
  }
  return line;
}

// Carries the outcome of the background start from the worker thread back to
// the GTK main thread, where fl_method_call_respond_* must be invoked.
struct StartServerResult {
  FlMethodCall* method_call;  // holds a ref; released after responding
  bool success;
  int port;
  std::string token;
  std::string error_code;
  std::string error_message;
};

// Runs on the GTK main thread via g_idle_add to deliver the response.
static gboolean start_server_respond_idle(gpointer data) {
  StartServerResult* r = static_cast<StartServerResult*>(data);
  if (r->success) {
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "port", fl_value_new_int(r->port));
    fl_value_set_string_take(result, "token",
                             fl_value_new_string(r->token.c_str()));
    fl_method_call_respond_success(r->method_call, result, nullptr);
  } else {
    fl_method_call_respond_error(r->method_call, r->error_code.c_str(),
                                 r->error_message.c_str(), nullptr, nullptr);
  }
  g_object_unref(r->method_call);
  delete r;
  return G_SOURCE_REMOVE;
}

// Runs on a background thread: spawns the child and reads its startup line
// (up to 10s) without blocking the GTK main thread. Responds via g_idle_add.
static void start_server_worker(PionbridgePlugin* self,
                                 FlMethodCall* method_call) {
  StartServerResult* r = new StartServerResult();
  r->method_call = method_call;  // ownership of the ref taken by the caller
  r->success = false;

  auto fail = [&](const char* code, const std::string& message) {
    r->success = false;
    r->error_code = code;
    r->error_message = message;
    g_idle_add(start_server_respond_idle, r);
  };

  // Serialize the whole start against dispose/stopServer/other starts.
  // Two rapid startServer calls must not interleave: the second would
  // overwrite (and leak) the first's pid mid-spawn.
  std::lock_guard<std::mutex> lock(server_mutex);

  // Kill any existing server (reaped by its child watch).
  if (self->server_pid != 0) {
    kill(self->server_pid, SIGTERM);
    self->server_pid = 0;
  }
  if (self->stdout_fd >= 0) {
    close(self->stdout_fd);
    self->stdout_fd = -1;
  }
  if (self->stdin_fd >= 0) {
    close(self->stdin_fd);
    self->stdin_fd = -1;
  }

  std::string binary_path = get_binary_path();
  if (binary_path.empty() || access(binary_path.c_str(), X_OK) != 0) {
    fail("BINARY_NOT_FOUND",
         "pionbridge binary not found or not executable at: " + binary_path);
    return;
  }

  gchar* argv[] = {const_cast<gchar*>(binary_path.c_str()), nullptr};
  gint child_stdin = -1;
  gint child_stdout = -1;
  GError* error = nullptr;

  gboolean spawned = g_spawn_async_with_pipes(
      nullptr,    // working dir
      argv,
      nullptr,    // envp (inherit)
      G_SPAWN_DO_NOT_REAP_CHILD,
      nullptr, nullptr,
      &self->server_pid,
      &child_stdin,   // stdin: a pipe we hold open (parent-death signal)
      &child_stdout,  // stdout
      nullptr,        // stderr (let it go to terminal)
      &error);

  if (!spawned) {
    std::string msg = error ? error->message : "unknown error";
    g_clear_error(&error);
    fail("SERVER_START_FAILED", msg);
    return;
  }

  // Reap the child whenever it exits (see child_exited_cb).
  g_child_watch_add(self->server_pid, child_exited_cb, nullptr);

  self->stdout_fd = child_stdout;
  self->stdin_fd = child_stdin;

  auto fail_and_kill = [&](const std::string& message) {
    kill(self->server_pid, SIGTERM);
    self->server_pid = 0;
    close(self->stdout_fd);
    self->stdout_fd = -1;
    close(self->stdin_fd);
    self->stdin_fd = -1;
    fail("SERVER_START_FAILED", message);
  };

  // Read the startup JSON line (10s timeout)
  std::string line = read_line_timeout(child_stdout, 10);
  if (line.empty()) {
    fail_and_kill("No startup JSON from Go server (timed out)");
    return;
  }

  // Parse {"port":<int>,"token":"<str>"}
  // Minimal inline parse — avoids pulling in a JSON library.
  int port = 0;
  std::string token;

  auto extract_int = [&](const std::string& key) -> int {
    auto pos = line.find("\"" + key + "\"");
    if (pos == std::string::npos) return 0;
    pos = line.find(':', pos);
    if (pos == std::string::npos) return 0;
    return std::stoi(line.substr(pos + 1));
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
    fail_and_kill("Failed to parse startup JSON: " + line);
    return;
  }

  r->success = true;
  r->port = port;
  r->token = token;
  g_idle_add(start_server_respond_idle, r);
}

static void handle_start_server(PionbridgePlugin* self,
                                 FlMethodCall* method_call) {
  // Keep the call alive across the worker thread; the idle callback releases it.
  g_object_ref(method_call);
  std::thread(start_server_worker, self, method_call).detach();
}

static void handle_stop_server(PionbridgePlugin* self,
                                FlMethodCall* method_call) {
  {
    std::lock_guard<std::mutex> lock(server_mutex);
    if (self->server_pid != 0) {
      kill(self->server_pid, SIGTERM);
      self->server_pid = 0;
    }
    if (self->stdout_fd >= 0) {
      close(self->stdout_fd);
      self->stdout_fd = -1;
    }
    if (self->stdin_fd >= 0) {
      close(self->stdin_fd);
      self->stdin_fd = -1;
    }
  }
  fl_method_call_respond_success(method_call, nullptr, nullptr);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                            gpointer user_data) {
  PionbridgePlugin* self = PIONBRIDGE_PLUGIN(user_data);
  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "startServer") == 0) {
    handle_start_server(self, method_call);
  } else if (strcmp(method, "stopServer") == 0) {
    handle_stop_server(self, method_call);
  } else {
    fl_method_call_respond_not_implemented(method_call, nullptr);
  }
}

void pionbridge_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  PionbridgePlugin* plugin = PIONBRIDGE_PLUGIN(
      g_object_new(pionbridge_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "io.pion_bridge.bridge",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->channel, method_call_cb, plugin, g_object_unref);
}
