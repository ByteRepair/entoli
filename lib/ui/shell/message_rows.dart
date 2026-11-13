import "package:entoli_glass/entoli_glass.dart" as wire;
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/spec.dart" show SettingReader;
import "../../app/transcript/message.dart" show MessageBlock;
import "../../app/transcript/transcript.dart" show MessageRow;
import "../../domain/models.dart" show Message;
import "markdown_encoder.dart" show FormulaSheet;
import "tracking_reader.dart";
import "transcript_encoder.dart";

/// The conversation's message rows as last encoded, each kept while what it
/// was built from holds. A row is built under a reader of its own, so what
/// only it read — a plan, a job, a face — re-encodes that row alone, and a
/// row whose message and inputs are as they were is not laid out, encoded
/// or compared again: a streamed delta costs the row that grew.
class MessageRows {
  MessageRows(this._container, {required this.republish});

  final ProviderContainer _container;

  /// Asks for a pass: something a kept row read has changed.
  final void Function() republish;

  final _rows = <String, _Row>{};

  /// [row]'s snapshot, encoded again only where its message or [inputs]
  /// changed, or something its last encoding read did. [encoder] makes the
  /// row's encoder over the reader it is read through, and [build] encodes
  /// it with that encoder and reader. Null where the kept one still holds.
  wire.RowSnapshot? encode(
    MessageRow row,
    Object inputs, {
    required FormulaSheet formulas,
    required TranscriptEncoder Function(SettingReader reader) encoder,
    required wire.MessageSnapshot Function(
      TranscriptEncoder encoder,
      SettingReader reader,
    )
    build,
  }) {
    final kept = _rows[row.key];
    if (kept != null && !kept.dirty && kept.holds(row.message, inputs)) {
      return null;
    }
    final entry = kept ?? (_rows[row.key] = _Row(_container, republish));
    entry.reader.pass(() {
      final misses = formulas.misses;
      final rowEncoder = encoder(entry.reader);
      entry
        ..message = row.message
        ..inputs = inputs
        ..encoder = rowEncoder
        ..snapshot = wire.RowSnapshot(
          key: row.key,
          message: build(rowEncoder, entry.reader),
        )
        ..pending = formulas.misses != misses
        ..dirty = false;
    });
    return entry.snapshot;
  }

  /// A formula landed: the rows still waiting on one are encoded again.
  void formulaLanded() {
    for (final row in _rows.values) {
      if (row.pending) row.dirty = true;
    }
  }

  /// The node an intent names, among the kept rows' own.
  EncodedNode? node(String id) {
    final slash = id.indexOf("/");
    if (slash < 0) return null;
    return _rows[id.substring(0, slash)]?.encoder?.nodes[id];
  }

  /// Row [key]'s blocks as last laid out.
  List<MessageBlock>? blocks(String key) => _rows[key]?.encoder?.blocks[key];

  /// Lets go of every row not in [keys].
  void keep(Set<String> keys) {
    _rows.removeWhere((key, row) {
      if (keys.contains(key)) return false;
      row.reader.close();
      return true;
    });
  }

  void clear() => keep(const {});
}

class _Row {
  _Row(ProviderContainer container, void Function() republish) {
    reader = TrackingReader(container, () {
      dirty = true;
      republish();
    });
  }

  late final TrackingReader reader;
  Message? message;
  Object? inputs;
  TranscriptEncoder? encoder;
  wire.RowSnapshot? snapshot;

  /// Something its encoding read has changed since.
  bool dirty = true;

  /// A formula in it had not landed when it was encoded.
  bool pending = false;

  bool holds(Message now, Object nowInputs) =>
      (identical(message, now) || message == now) && inputs == nowInputs;
}
