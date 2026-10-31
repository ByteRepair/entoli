import "dart:async";
import "dart:math";

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
    ["close", final int worker, final String? error] => CloseFrame(
      worker,
      error: error,
    ),
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

/// Stop [worker], or, coming back, [worker] has stopped — with [error] where
/// it never started, which is the host's to say rather than the worker's.
class CloseFrame extends HostFrame {
  const CloseFrame(this.worker, {this.error});

  final int worker;
  final String? error;

  @override
  List<Object?> get fields => ["close", worker, error];
}

/// Frames as bytes: a four-byte big-endian length, then the frame's fields in
/// the standard message codec.
class FrameCodec {
  const FrameCodec();

  static const _codec = StandardMessageCodec();

  /// [frame] as its header and its body, written one after the other: the
  /// body is the codec's own buffer, never copied to sit behind the header.
  List<Uint8List> encode(HostFrame frame) {
    final body = _codec.encodeMessage(frame.fields)!;
    final header = Uint8List(4);
    ByteData.sublistView(header).setUint32(0, body.lengthInBytes);
    return [header, Uint8List.sublistView(body)];
  }

  /// A socket's chunks into frames. A chunk ends wherever the network put the
  /// end, so a frame — its header included — may arrive in pieces or several
  /// to a chunk.
  ///
  /// Each body is copied once, into a buffer of its own length allocated when
  /// its header is whole. A buffer of its own is also what the codec needs:
  /// it reads a typed list straight out of the bytes, which wants them
  /// aligned to its element size, and a fresh buffer starts at offset 0
  /// where a view into a chunk starts wherever the frame before it ended.
  StreamTransformer<Uint8List, HostFrame> get decoder =>
      StreamTransformer.fromBind((chunks) async* {
        final header = Uint8List(4);
        var headerFilled = 0;
        Uint8List? body;
        var bodyFilled = 0;
        await for (final chunk in chunks) {
          var at = 0;
          while (at < chunk.length) {
            if (body == null) {
              final n = min(header.length - headerFilled, chunk.length - at);
              header.setRange(headerFilled, headerFilled + n, chunk, at);
              headerFilled += n;
              at += n;
              if (headerFilled < header.length) break;
              body = Uint8List(ByteData.sublistView(header).getUint32(0));
              headerFilled = 0;
              bodyFilled = 0;
            }
            final n = min(body.length - bodyFilled, chunk.length - at);
            body.setRange(bodyFilled, bodyFilled + n, chunk, at);
            bodyFilled += n;
            at += n;
            if (bodyFilled < body.length) break;
            yield HostFrame.decode(
              _codec.decodeMessage(ByteData.sublistView(body)),
            );
            body = null;
          }
        }
      });
}
