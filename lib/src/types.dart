import 'dart:convert';

class IceServer {
  final List<String> urls;
  final String? username;
  final String? credential;

  IceServer({
    required this.urls,
    this.username,
    this.credential,
  });

  Map<String, dynamic> toMap() => {
        'urls': urls,
        if (username != null) 'username': username,
        if (credential != null) 'credential': credential,
      };
}

class IceCandidate {
  final String candidate;
  final String sdpMid;
  final int sdpMlineIndex;

  IceCandidate({
    required this.candidate,
    required this.sdpMid,
    required this.sdpMlineIndex,
  });
}

class DataChannelMessage {
  final String data;
  final bool isBinary;

  DataChannelMessage({required this.data, required this.isBinary});

  List<int> get binaryData => base64Decode(data);
}

enum ConnectionState {
  newConnection,
  connecting,
  connected,
  disconnected,
  failed,
  closed;

  static ConnectionState fromString(String state) {
    if (state == 'new') return ConnectionState.newConnection;
    return ConnectionState.values.byName(state);
  }
}
