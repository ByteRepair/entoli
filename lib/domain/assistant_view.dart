/// Which view a launch from the system's assistant gesture opens. Declaration
/// order is the order the settings page offers them in.
///
/// A separate enum rather than a bool: voice mode is a second view rather than
/// the negation of chat, and the setting is structured so a third can join
/// without the field changing shape. See issue #54.
enum AssistantView {
  chat("Chat view"),
  voice("Voice view");

  const AssistantView(this.label);

  final String label;

  /// An unknown name is a file written by a later build, so it falls back
  /// rather than failing the whole settings load.
  static AssistantView fromName(String? name) =>
      values.firstWhere((view) => view.name == name, orElse: () => chat);
}