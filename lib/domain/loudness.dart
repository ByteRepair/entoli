import "dart:math" as math;

/// [amplitude] — the RMS of samples in -1..1 — as decibels full scale, which is
/// the scale a microphone's own numbers land on: a quiet room around -50, and
/// someone talking at arm's length around -20. Silence is a floor rather than
/// negative infinity, since what reads this does arithmetic on it.
double decibels(double amplitude) =>
    20 * math.log(math.max(amplitude, _quietest)) / math.ln10;

/// -100 dB, which is quieter than any microphone's own noise.
const _quietest = 1e-5;

/// Whether an utterance was loud enough to have been meant for the phone, from
/// the loudness measured while it was heard.
///
/// Both engines are generous about what counts as speech, in their own ways: a
/// system recogniser transcribes a fan, a television and the next room over,
/// and Silero calls plenty of it voice. Every one of those was a turn. Neither
/// offers a threshold worth raising, so the utterance is judged after the fact.
///
/// **There is not a single absolute number in here, and the first version's
/// bug is why.** It compared the utterance against the room plus a fixed
/// margin, in the units `onRmsChanged` reports — whose documented -2 to 10 is a
/// typical range and not a contract. On a device reporting a narrower one the
/// margin was unreachable, so *nothing* was ever loud enough and voice mode
/// answered nobody. A gate that can be wrong that way is worse than no gate:
/// its failure is silent, and it looks exactly like a broken microphone.
///
/// So the bar is a share of how loud this person turns out to be, which is
/// measured rather than assumed:
///
///  * Nothing is refused until a voice has been heard to compare against. The
///    first utterance always carries, whatever it was.
///  * That utterance sets the level, and the bar is a fraction of it. Someone
///    talking to the phone clears it; a television across the room does not.
///  * A level set by the wrong thing corrects itself upward, since a real voice
///    is louder than the television that set it — and downward, since the level
///    decays a little at every judgement, so a bar raised by one shout is not
///    the bar for the rest of the session.
///
/// What is left of the room is the *floor* the utterance is measured above, and
/// that is a minimum rather than an average: a floor that follows what it hears
/// climbs into a long sentence and reports that nobody said anything. It is the
/// quietest reading of the last two blocks, so it takes a genuinely quieter
/// room to move it and no amount of talking will.
class LoudnessGate {
  /// Of the loudest utterance measured, what a later one has to reach. Well
  /// under a half, so the same person saying the same thing more quietly, or
  /// further from the phone, still carries.
  static const _share = 0.4;

  /// What the level is multiplied by at each judgement. Slow enough that the
  /// bar holds across a conversation, fast enough that one shout is forgotten
  /// within a dozen turns.
  static const _forget = 0.93;

  /// Readings per block of the floor's memory. Both engines report somewhere
  /// between ten and thirty a second, so two blocks is a few seconds of room —
  /// long enough to span a sentence, short enough to follow a room that has
  /// genuinely changed.
  static const _block = 48;

  double _floor = 0;
  bool _measured = false;

  /// The quietest reading of the block being filled, and of the one before it.
  double _thisBlock = double.infinity;
  double _lastBlock = double.infinity;
  int _seen = 0;

  /// How far above the floor this person turns out to be. Set by what carries,
  /// and what the bar is a share of.
  double _voice = 0;

  /// The loudest anything has been, for the circle to be drawn against. Every
  /// reading counts toward it, unlike [_voice], because the circle has to move
  /// before anyone has said a word — and it fades, so one door slamming does
  /// not flatten it for the session.
  double _loudest = 0;
  static const _fade = 0.9995;

  /// The loudest reading of this utterance, above the floor. Null rather than
  /// zero for nothing measured since the last result, which is the one case the
  /// gate has to let through rather than refuse.
  double? _peak;

  double _level = 0;

  /// One reading, in whatever units the engine behind it reports. What they are
  /// does not matter, so long as they are the same ones every time.
  void measure(double reading) {
    _thisBlock = math.min(_thisBlock, reading);
    if (++_seen >= _block) {
      _lastBlock = _thisBlock;
      _thisBlock = double.infinity;
      _seen = 0;
    }
    _floor = math.min(_thisBlock, _lastBlock);
    _measured = true;

    final above = math.max(0.0, reading - _floor);
    _peak = math.max(_peak ?? above, above);
    _loudest = math.max(_loudest * _fade, above);
    _level = _loudest > 0 ? (above / _loudest).clamp(0.0, 1.0) : 0;
  }

  /// Whether what has been heard since the last result was loud enough, for
  /// this person, to have been said to the phone. Ends the utterance either
  /// way.
  ///
  /// True where there is nothing to judge on — an engine that reports no
  /// loudness at all, none during this utterance, or no voice yet to compare
  /// against. A gate that cannot measure has no business refusing.
  bool spoken() {
    final peak = _peak;
    _endUtterance();
    if (peak == null || !_measured) return true;
    // Decayed before the comparison rather than after it, so a bar that has
    // been refusing things comes down whether or not anything gets past it.
    _voice *= _forget;
    if (peak < _voice * _share) return false;
    _voice = math.max(_voice, peak);
    return true;
  }

  /// How loud it is now against the loudest it has been, 0 to 1 — what the orb
  /// follows. Relative for the same reason the bar is: there is no scale here
  /// to draw a circle against.
  double get level => _level;

  /// The microphone has been shut. The utterance in progress goes with it; the
  /// floor and what has been learned stay, since the room is the same room a
  /// moment later and the person is the same person.
  void quiet() => _endUtterance();

  void _endUtterance() {
    _peak = null;
    _level = 0;
  }
}
