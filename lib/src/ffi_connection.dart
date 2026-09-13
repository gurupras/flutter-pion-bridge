import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bridge_connection.dart';
import 'exception.dart';
import 'ws_message.dart';

typedef _FrameCallback = Void Function(
    Int64 session, Pointer<Uint8> data, Int32 len);

/// The in-process bridge library (go/shared) as seen from Dart.
final class _SharedLibrary {
  final int Function(Pointer<NativeFunction<_FrameCallback>>) open;
  final int Function(int, Pointer<Uint8>, int) send;
  final void Function(int) close;
  final Pointer<NativeFinalizerFunction> free;

  _SharedLibrary(DynamicLibrary lib)
      : open = lib.lookupFunction<
            Int64 Function(Pointer<NativeFunction<_FrameCallback>>),
            int Function(
                Pointer<NativeFunction<_FrameCallback>>)>('PionBridgeOpen'),
        send = lib.lookupFunction<Int32 Function(Int64, Pointer<Uint8>, Int32),
            int Function(int, Pointer<Uint8>, int)>('PionBridgeSend'),
        close = lib.lookupFunction<Void Function(Int64), void Function(int)>(
            'PionBridgeClose'),
        free = lib.lookup<NativeFinalizerFunction>('PionBridgeFree');

  // Per isolate; the underlying library (and its Go runtime) is process-wide.
  static final Map<String, _SharedLibrary> _loaded = {};

  static _SharedLibrary load(String path) =>
      _loaded[path] ??= _SharedLibrary(DynamicLibrary.open(path));
}

/// Protocol session with the bridge loaded in-process (shared mode): frames go
/// through dart:ffi calls instead of a localhost WebSocket, so there is no
/// sidecar process, no socket and no token.
///
/// Inbound frames arrive on this isolate via a [NativeCallable.listener] and
/// are wrapped zero-copy: the native buffer is released by a finalizer when
/// the frame (and anything decoded as a view of it) is garbage collected.
/// Outbound frames are copied once into a reusable native buffer; the library
/// copies them again before [PionBridgeSend] returns.
class FfiConnection extends BridgeConnection {
  final _SharedLibrary _lib;
  late final NativeCallable<_FrameCallback> _callback;
  late final int _session;
  bool _open = false;

  Pointer<Uint8> _sendBuf = nullptr;
  int _sendCap = 0;

  FfiConnection._(this._lib, {required super.onMessage, super.requestTimeout});

  /// Loads the library (once per isolate) and opens a session. Safe to call
  /// from any isolate — no MethodChannel is involved.
  static FfiConnection open({
    required void Function(WsMessage) onMessage,
    String? libraryPath,
    Duration requestTimeout = const Duration(seconds: 30),
  }) {
    final path = libraryPath ?? defaultLibraryPath();
    final _SharedLibrary lib;
    try {
      lib = _SharedLibrary.load(path);
    } on ArgumentError catch (e) {
      throw PionException(
          'SERVER_START_FAILED', 'cannot load pion bridge library $path: $e',
          fatal: true);
    }
    final conn = FfiConnection._(lib,
        onMessage: onMessage, requestTimeout: requestTimeout);
    conn._callback = NativeCallable<_FrameCallback>.listener(conn._onFrame);
    conn._session = lib.open(conn._callback.nativeFunction);
    conn._open = true;
    return conn;
  }

  /// Where the plugin bundles the shared library.
  static String defaultLibraryPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isLinux) return '$exeDir/lib/libpionbridge.so';
    throw UnsupportedError(
        'pion_bridge shared mode is not bundled for ${Platform.operatingSystem} '
        'yet; pass libraryPath to load a library you built yourself');
  }

  void _onFrame(int session, Pointer<Uint8> data, int len) {
    final frame = data.asTypedList(len, finalizer: _lib.free, token: data.cast());
    // A frame posted just before close() may still be delivered; drop it (the
    // finalizer frees it). Frames still queued when the callable closes are
    // discarded by the VM without running this, leaking at most that tail.
    if (!_open) return;
    handleFrame(frame);
  }

  @override
  bool get isConnected => _open;

  @override
  String get transportName => 'Shared library session';

  @override
  void sendFrame(Uint8List frame) {
    if (frame.length > _sendCap) {
      if (_sendBuf != nullptr) malloc.free(_sendBuf);
      _sendCap = frame.length < 4096 ? 4096 : frame.length * 2;
      _sendBuf = malloc<Uint8>(_sendCap);
    }
    _sendBuf.asTypedList(frame.length).setAll(0, frame);
    if (_lib.send(_session, _sendBuf, frame.length) != 0) {
      throw PionException('CONNECTION_LOST', 'shared session $_session closed',
          fatal: true);
    }
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    failPending('Connection closed');
    // Returns only once the library has stopped invoking the callback, so the
    // callable can be released right after.
    _lib.close(_session);
    _callback.close();
    if (_sendBuf != nullptr) {
      malloc.free(_sendBuf);
      _sendBuf = nullptr;
      _sendCap = 0;
    }
  }
}
