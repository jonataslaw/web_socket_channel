// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';

import 'src/channel.dart';
import 'src/exception.dart';
import 'src/sink_completer.dart';

/// A [WebSocketChannel] that communicates using a `dart:io` [WebSocket].
class IOWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  /// The underlying `dart:io` [WebSocket].
  ///
  /// If the channel was constructed with [IOWebSocketChannel.connect], this is
  /// `null` until the [WebSocket.connect] future completes.
  WebSocket? _webSocket;

  @override
  String? get protocol => _webSocket?.protocol;

  @override
  int? get closeCode => _webSocket?.closeCode;

  @override
  String? get closeReason => _webSocket?.closeReason;

  @override
  final Stream stream;
  @override
  final WebSocketSink sink;

  // TODO(nweiz): Add a compression parameter after the initial release.

  /// Creates a new WebSocket connection.
  ///
  /// Connects to [url] using [WebSocket.connect] and returns a channel that can
  /// be used to communicate over the resulting socket. The [url] may be either
  /// a [String] or a [Uri]. The [protocols] and [headers] parameters are the
  /// same as [WebSocket.connect].
  ///
  /// [pingInterval] controls the interval for sending ping signals. If a ping
  /// message is not answered by a pong message from the peer, the WebSocket is
  /// assumed disconnected and the connection is closed with a `goingAway` code.
  /// When a ping signal is sent, the pong message must be received within
  /// [pingInterval]. It defaults to `null`, indicating that ping messages are
  /// disabled.
  ///
  /// If there's an error connecting, the channel's stream emits a
  /// [WebSocketChannelException] wrapping that error and then closes.
  factory IOWebSocketChannel.connect(
    Object url, {
    Iterable<String>? protocols = const <String>['graphql-ws'],
    Map<String, dynamic>? headers,
    Duration? pingInterval,
  }) {
    late IOWebSocketChannel channel;
    final sinkCompleter = WebSocketSinkCompleter();
    final stream = StreamCompleter.fromFuture(
      createWebsocket(url.toString(), headers: headers, protocols: protocols!)
          .then((webSocket) {
        webSocket.pingInterval = pingInterval;
        channel._webSocket = webSocket;
        sinkCompleter.setDestinationSink(_IOWebSocketSink(webSocket));
        return webSocket;
      }).catchError(
        (Object error) => throw WebSocketChannelException.from(error),
      ),
    );

    return channel =
        IOWebSocketChannel._withoutSocket(stream, sinkCompleter.sink);
  }

  /// Creates a channel wrapping [socket].
  IOWebSocketChannel(WebSocket socket)
      : _webSocket = socket,
        stream = socket.handleError(
            (error) => throw WebSocketChannelException.from(error)),
        sink = _IOWebSocketSink(socket);

  /// Creates a channel without a socket.
  ///
  /// This is used with `connect` to synchronously provide a channel that later
  /// has a socket added.
  IOWebSocketChannel._withoutSocket(Stream stream, this.sink)
      : _webSocket = null,
        stream = stream.handleError(
            (error) => throw WebSocketChannelException.from(error));
}

/// A [WebSocketSink] that forwards [close] calls to a `dart:io` [WebSocket].
class _IOWebSocketSink extends DelegatingStreamSink implements WebSocketSink {
  /// The underlying socket.
  final WebSocket _webSocket;

  _IOWebSocketSink(WebSocket webSocket)
      : _webSocket = webSocket,
        super(webSocket);

  @override
  Future close([int? closeCode, String? closeReason]) =>
      _webSocket.close(closeCode, closeReason);
}

Future<WebSocket> createWebsocket(String url,
    {required Iterable<String> protocols,
    Map<String, dynamic>? headers}) async {
  final _httpClient = HttpClient();
  var uri = Uri.parse(url);

  final random = Random();
  // Generate 16 random bytes.
  final nonceData = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    nonceData[i] = random.nextInt(256);
  }
  final nonce = base64.encode(nonceData);
  uri = Uri(
      scheme: uri.scheme == 'wss' ? 'https' : 'http',
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.port,
      path: uri.path,
      query: uri.query,
      fragment: uri.fragment);
  final request = await _httpClient.openUrl('GET', uri);
  if (uri.userInfo.isNotEmpty) {
    print(uri.userInfo);
    // If the URL contains user information use that for basic
    // authorization.
    final auth = base64.encode(utf8.encode(uri.userInfo));
    request.headers.set(HttpHeaders.authorizationHeader, 'Basic $auth');
  }
  // Setup the initial handshake.
  request.headers
    ..set(HttpHeaders.connectionHeader, 'Upgrade')
    ..set(HttpHeaders.upgradeHeader, 'websocket')
    ..set('Sec-WebSocket-Key', nonce)
    ..set('Cache-Control', 'no-cache')
    ..set('Sec-WebSocket-Version', '13')
    ..set('Sec-WebSocket-Protocol', protocols.first);
  request.headers.removeAll('content-length');
  if (headers != null) {
    headers.forEach((key, value) {
      print('setting header ${HttpHeaders.authorizationHeader} $value');
      request.headers.set(HttpHeaders.authorizationHeader, value as Object);
    });
  }

  print(request.headers);
  final response = await request.close();

  final socket = await response.detachSocket();
  final websocket = WebSocket.fromUpgradedSocket(socket,
      protocol: protocols.first, serverSide: false);
  return websocket;
}
