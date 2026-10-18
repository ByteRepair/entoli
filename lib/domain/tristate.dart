/// A setting with an answer of its own either way, or none: [inherit] defers
/// to whatever the tier above says.
enum Tristate {
  off("Off"),
  inherit("Inherit"),
  on("On");

  const Tristate(this.label);

  final String label;
}
