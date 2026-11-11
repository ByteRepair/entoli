/// How the agents of a project's rounds run. The project's Omada section
/// names the default for its chats; a chat's own override, where Phase 2
/// adds one, wins over it.
enum OmadaOrdering {
  sequential,
  parallel,
  relay;

  /// Whether the room waits for every running turn to end before it hands
  /// off or dispatches what was said meanwhile. Relay alone does not.
  bool get waitsForWave => this != relay;

  /// Whether a dispatch pass may start a member's next item. [started] is how
  /// many items this pass has started; [memberBusy], whether the member has a
  /// turn in flight. The room-wide wait is [waitsForWave]'s, at the callers.
  bool admits({required int started, required bool memberBusy}) =>
      switch (this) {
        sequential => started == 0,
        parallel => true,
        relay => !memberBusy,
      };
}

/// Human-readable labels, shared by the project settings page so the
/// dropdown and the section's inherited entry name the same thing. The
/// parallel ordering is Crossfire: several members working at the same time,
/// each writing their own reply. Relay is the same start with no wave
/// barrier: what a reply names runs while its siblings are still speaking.
const omadaOrderingLabels = {
  OmadaOrdering.sequential: "Sequential",
  OmadaOrdering.parallel: "Crossfire",
  OmadaOrdering.relay: "Relay",
};

/// One line each, under the ordering dropdown: what the round does under
/// that ordering. The description shown is the effective one — the
/// project's pick, else the app default, else relay.
const omadaOrderingDescriptions = {
  OmadaOrdering.sequential:
      "Members run one after another, in the order "
      "the message names them.",
  OmadaOrdering.parallel:
      "Members run at the same time, each writes their "
      "own reply, in whatever order they finish.",
  OmadaOrdering.relay:
      "Members start as soon as they are named, without "
      "waiting for the room to settle.",
};

/// The default when nothing is set anywhere: relay.
const defaultOmadaOrdering = OmadaOrdering.relay;
