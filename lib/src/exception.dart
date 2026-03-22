import 'ws_message.dart';

class PionException implements Exception {
  final String code;
  final String message;
  final bool fatal;
  final String? handle;

  PionException(
    this.code,
    this.message, {
    this.fatal = false,
    this.handle,
  });

  factory PionException.fromWsMessage(WsMessage msg) {
    final error = msg.data;
    return PionException(
      (error['code'] as String?) ?? 'UNKNOWN',
      (error['message'] as String?) ?? 'Unknown error',
      fatal: error['fatal'] as bool? ?? false,
      handle: error['handle'] as String?,
    );
  }

  @override
  String toString() => 'PionException($code): $message';
}
