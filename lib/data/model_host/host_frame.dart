import "dart:async";
import "dart:typed_data";

import "package:flutter/services.dart";

/// What crosses between the app and its model host, one value per frame.
///
/// A frame is its [fields]: a tag, then values Flutter's standard message
/// codec carries — the same values a method channel or an isolate port does,
/// which is what lets a channel call or a worker's message cross unchanged.
sealed class HostFrame {
  const HostFrame();

  List<Object?> get fields;

  static HostFrame decode(Object? value) => switch (value) {
    ["hello", final String key] => HelloFrame(key),
    [
      "call",
      final int id,
      final String channel,
      final String method,
      final a,
    ] =>
      CallFrame(id, channel, method, a),
    ["reply", final int id, final result] => ReplyFrame(id, result),
    ["fail", final int id, final String code, final String? message] =>
      FailFrame(id, code, message),
    ["event", final String channel, final String method, final arguments] =>
      EventFrame(channel, method, arguments),
    ["spawn", final int worker, final String kind, final List<Object?> a] =>
      SpawnFrame(worker, kind, a),
    ["post", final int worker, final message] => PostFrame(worker, message),
    ["close", final int worker] => CloseFrame(worker),
    _ => throw FormatException("Not a model host frame: $value"),
  };
}

/// The host's first word: the key the app handed it, which is what tells the
/// app the connection is its own host's.
class HelloFrame extends HostFrame {
  const HelloFrame(this.key);

  final String key;

  @override
  List<Object?> get fields => ["hello", key];
}

/// A method call on one of the host's channels, answered by the [ReplyFrame]
/// or [FailFrame] carrying the same [id].
class CallFrame extends HostFrame {
  const CallFrame(this.id, this.channel, this.method, this.arguments);

  final int id;
  final String channel;
  final String method;
  final Object? arguments;

  @override
  List<Object?> get fields => ["call", id, channel, method, arguments];
}

class ReplyFrame extends HostFrame {
  const ReplyFrame(this.id, this.result);

  final int id;
  final Object? result;

  @override
  List<Object?> get fields => ["reply", id, result];
}

/// A call that threw: a [PlatformException]'s code and message, so the caller
/// meets the exception a channel in its own process would have thrown.
class FailFrame extends HostFrame {
  const FailFrame(this.id, this.code, this.message);

  final int id;
  final String code;
  final String? message;

  @override
  List<Object?> get fields => ["fail", id, code, message];
}

/// What a channel's native half said unasked — a generation's text, its end.
class EventFrame extends HostFrame {
  const EventFrame(this.channel, this.method, this.arguments);

  final String channel;
  final String method;
  final Object? arguments;

  MethodCall get call => MethodCall(method, arguments);

  @override
  List<Object?> get fields => ["event", channel, method, arguments];
}

/// Start a worker of [kind] in the host, addressed as [worker] from here on.
class SpawnFrame extends HostFrame {
  const SpawnFrame(this.worker, this.kind, this.argument);

  final int worker;
  final String kind;
  final List<Object?> argument;

  @override
  List<Object?> get fields => ["spawn", worker, kind, argument];
}

/// One message to or from [worker], whichever way the frame is going.
class PostFrame extends HostFrame {
  const PostFrame(this.worker, this.message);

  final int worker;
  final Object? message;

  @override
  List<Object?> get fields => ["post", worker, message];
}

/// Stop [worker], or, coming back, [worker] has stopped.
class CloseFrame extends HostFrame {
  const CloseFrame(this.worker);

  final int worker;

  @override
  List<Object?> get fields => ["close", worker];
}

/// Frames as bytes: a four-byte big-endian length, then the frame's fields in
/// the standard message codec.
class FrameCodec {
  const FrameCodec();

  static const _codec = StandardMessageCodec();

  Uint8List encode(HostFrame frame) {
    final body = _codec.encodeMessage(frame.fields)!;
    final out = Uint8List(4 + body.lengthInBytes);
    ByteData.sublistView(out).setUint32(0, body.lengthInBytes);
    out.setRange(
      4,
      out.length,
      body.buffer.asUint8List(body.offsetInBytes, body.lengthInBytes),
    );
    return out;
  }

  /// A socket's chunks into frames. A chunk ends wherever the network put the
  /// end, so a frame may arrive in pieces or several to a chunk.
  StreamTransformer<Uint8List, HostFrame> get decoder =>
      StreamTransformer.fromBind((chunks) async* {
        final pending = BytesBuilder(copy: false);
        await for (final chunk in chunks) {
          pending.add(chunk);
          final bytes = pending.takeBytes();
          var at = 0;
          while (bytes.length - at >= 4) {
            final length = ByteData.sublistView(bytes, at).getUint32(0);
            if (bytes.length - at - 4 < length) break;
            // A copy, not a view: the codec reads a typed list straight out
            // of the buffer, which wants it aligned to its element size, and
            // a frame starts wherever the one before it ended.
            final body = Uint8List.fromList(
              Uint8List.sublistView(bytes, at + 4, at + 4 + length),
            );
            yield HostFrame.decode(
              _codec.decodeMessage(ByteData.sublistView(body)),
            );
            at += 4 + length;
          }
          if (at < bytes.length) pending.add(Uint8List.sublistView(bytes, at));
        }
      });
}
