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
}
