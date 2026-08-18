/// How long a temporary chat lives after its TTL is enabled. Declaration
/// order is the order the settings page offers them in.
///
/// A temporary chat is hidden from the sidebar once its expiry passes and
/// deleted by a background sweep. The anchor and the denormalized expiry
/// live on `ChatState`; the resolved duration is recomputed on every save
/// from the anchor, so widening the app/project window extends an existing
/// chat from its original anchor.
enum TempChatTtl {
  off("Off"),
  hours24("24 hours"),
  days7("7 days"),
  month1("1 month"),
  year1("1 year");

  const TempChatTtl(this.label);

  final String label;

  /// An unknown name is a file written by a later build, so it falls back
  /// rather than failing the whole settings load.
  static TempChatTtl fromName(String? name) =>
      values.firstWhere((t) => t.name == name, orElse: () => off);

  /// Null when the key is absent, so a nullable field reads as "inherit".
  static TempChatTtl? fromNameNullable(String? name) => name == null
      ? null
      : values.cast<TempChatTtl?>().firstWhere((t) => t!.name == name, orElse: () => null);
}

/// Human-readable labels, shared by the app, project and chat settings pages
/// so they always agree.
const tempChatTtlLabels = {
  TempChatTtl.off: "Off",
  TempChatTtl.hours24: "24 hours",
  TempChatTtl.days7: "7 days",
  TempChatTtl.month1: "1 month",
  TempChatTtl.year1: "1 year",
};

/// The window a TTL opens. Null for [TempChatTtl.off]. A month is 30 days and
/// a year 365, as fixed [Duration]s: the codebase's tone is "dumb is fine", and
/// calendar arithmetic would be a second answer to one comparison.
Duration? tempChatTtlDuration(TempChatTtl t) => switch (t) {
      TempChatTtl.off => null,
      TempChatTtl.hours24 => const Duration(hours: 24),
      TempChatTtl.days7 => const Duration(days: 7),
      TempChatTtl.month1 => const Duration(days: 30),
      TempChatTtl.year1 => const Duration(days: 365),
    };