import "package:flutter/widgets.dart";

extension NearBottom on ScrollPosition {
  /// Whether the view is close enough to the end to count as reading the
  /// latest — which is what decides both whether a turn scrolls itself along
  /// and whether there is a way back down to offer. How close is the caller's,
  /// and is the only part of the rule that differs: a conversation gives
  /// itself a screenful, a five-line transcript one line.
  bool nearBottom(double slack) => maxScrollExtent - pixels <= slack;
}
