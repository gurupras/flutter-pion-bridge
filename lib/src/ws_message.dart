class WsMessage {
  final String type;
  final int id;
  final String? handle;
  final Map<String, dynamic> data;

  WsMessage({
    required this.type,
    required this.id,
    this.handle,
    required this.data,
  });

  Map<String, dynamic> toMap() => {
        'type': type,
        'id': id,
        if (handle != null) 'handle': handle,
        'data': data,
      };

  factory WsMessage.fromMap(Map<String, dynamic> map) => WsMessage(
        type: map['type'] as String,
        id: (map['id'] as num).toInt(),
        handle: map['handle'] as String?,
        data: Map<String, dynamic>.from(map['data'] as Map? ?? {}),
      );

  /// Builds a WsMessage directly from a freshly msgpack-decoded map without
  /// copying it first (the decoder's Map<dynamic,dynamic> is private to the
  /// caller, so a cast view is safe). Avoids two full map copies per inbound
  /// frame on the message hot path.
  factory WsMessage.fromDecoded(Map decoded) {
    final rawData = decoded['data'];
    return WsMessage(
      type: decoded['type'] as String,
      id: (decoded['id'] as num).toInt(),
      handle: decoded['handle'] as String?,
      data: rawData is Map
          ? rawData.cast<String, dynamic>()
          : <String, dynamic>{},
    );
  }
}
