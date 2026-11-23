/// Whether something the app can be told to do can be done now, and if not,
/// why not. A menu greys an item on [Unavailable] and needs no more; a
/// caller with somewhere to put words — Shortcuts, which shows an action's
/// failure to the user — says the [Unavailable.reason].
sealed class Availability {
  const Availability();

  bool get isAvailable => this is Available;
}

final class Available extends Availability {
  const Available();
}

final class Unavailable extends Availability {
  const Unavailable(this.reason);

  /// A sentence for the user: "No chat is open."
  final String reason;
}
