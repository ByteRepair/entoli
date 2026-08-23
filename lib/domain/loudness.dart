import "dart:math" as math;

/// Whether an utterance was loud enough to have been meant for the phone, from
/// the loudness the recogniser reports as it listens.
///
/// A system recogniser decides for itself when speech starts and stops, and it
/// is generous about it: a fan, a television, a conversation across the room
/// all come back as a transcription, and voice mode sends every one of them as
/// a turn. There is no threshold on `SpeechRecognizer` to raise, so the
/// utterance is judged after the fact, against what the room was doing just
/// before it.
///
/// **Nothing here is an absolute level, because there is no absolute level to
/// compare against.** `onRmsChanged` reports dB on a scale that is the
/// engine's — the documented -2..10 is a typical range and not a contract, and
/// a microphone's gain moves it further. What survives that is a *margin*: how
/// far this utterance rose above the room measured moments earlier, in whatever
/// units both were measured in.
///
/// The bar is the larger of a fixed margin and a share of the loudest utterance
/// so far, which is what makes it follow the person rather than the room. A
/// quiet room and a quiet voice work at the fixed margin; somewhere noisy, the
/// first thing said raises the bar behind it, and the fan does not clear it.
class LoudnessGate {
  /// The margin nothing gets under, before anything has been said to measure
  /// against — about a quarter of the range a phone reports.
  static const _margin = 3.0;

  /// Of the loudest utterance measured, what a later one has to reach. Under a
  /// half so that the same person saying the same thing more quietly still
  /// carries.
  static const _share = 0.45;

  /// What the loudest is multiplied by each time one carries, so a bar raised
  /// by shouting once comes back down over the next few turns rather than
  /// standing for the session.
  static const _forget = 0.9;

  /// How much of the way the floor moves toward a quieter room per reading, and
  /// toward a louder one. Asymmetric on purpose: the floor is what the room is
  /// doing when nobody is talking, so it has to drop to a room that has gone
  /// quiet within a second and barely follow speech at all — otherwise every
  /// utterance raises the bar it is about to be measured against.
  static const _fall = 0.25;
  static const _rise = 0.02;

  /// How far above the floor is drawn as a full circle.
  static const _span = 8.0;

  /// Readings of the room itself before the gate is entitled to refuse
  /// anything. The first thing anyone says may be the first thing the
  /// microphone ever heard, and a floor seeded from a voice would put the bar
  /// above the voice that set it.
  static const _settled = 5;

  double? _floor;
  int _room = 0;
  double _loudest = 0;
  bool _speaking = false;
  double _level = 0;

  /// The loudest reading of this utterance, above the floor. Null rather than
  /// zero for nothing measured since the last result, which is the one case the
  /// gate has to let through rather than refuse.
  double? _peak;

  /// One `onRmsChanged`, in whatever units the engine reports it in.
  void measure(double rms) {
    final floor = _floor ??= rms;
    if (!_speaking) {
      _floor = floor + (rms - floor) * (rms < floor ? _fall : _rise);
      _room++;
    }
    final above = rms - _floor!;
    _peak = math.max(_peak ?? above, above);
    _level = (above / _span).clamp(0.0, 1.0);
  }

  /// The service says an utterance has started, so what is measured from here
  /// is the person rather than the room. An engine that never reports it is
  /// judged the same way, a little less exactly: the floor follows a voice so
  /// slowly that an utterance barely lifts it.
  void speechBegan() => _speaking = true;

  /// Whether what has been heard since the last result rose far enough above
  /// the room to have been said to the phone. Ends the utterance either way.
  ///
  /// True where there is nothing to judge on — an engine that reports no
  /// loudness at all, none during this utterance, or none of the room yet. A
  /// gate that cannot measure has no business refusing.
  bool spoken() {
    final peak = _peak;
    _endUtterance();
    if (peak == null || _room < _settled) return true;
    if (peak < math.max(_margin, _loudest * _share)) return false;
    _loudest = math.max(_loudest * _forget, peak);
    return true;
  }

  /// How loud it is now against the room, 0 to 1 — what the orb follows. A
  /// level relative to the floor rather than to the scale's nominal range, so
  /// the circle moves the same amount in a quiet room and a noisy one.
  double get level => _level;

  /// The microphone has been shut. The utterance in progress goes with it; the
  /// floor stays, since the room is the same room a moment later and measuring
  /// it again from nothing is what would let the next utterance through
  /// unjudged.
  void quiet() => _endUtterance();

  void _endUtterance() {
    _peak = null;
    _speaking = false;
    _level = 0;
  }
}
