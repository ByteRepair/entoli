import "../../data/builtin/tools/agent_tool.dart";
import "../../data/builtin/tools/registry.dart";
import "../../domain/agent_definition.dart";

/// What an agent may be granted, listed whatever this device can run: the
/// file means the same on every device it reaches.
final grantableAgentTools = [
  for (final tool in agentTools(const ToolOffer()))
    if (tool.group != null) tool,
];

/// The tools an agent is granted as they are being picked. Two tools of one
/// name are one tool worded two ways (`bash` and its read-only form), so at
/// most one of them is on.
class AgentToolPicks {
  AgentToolPicks(AgentDefinition agent)
    : _listed = agent.tools != null,
      initial = agent.tools ?? defaults,
      _on = {...agent.tools ?? defaults};

  /// The ids on by default.
  static Set<String> get defaults => {
    for (final tool in grantableAgentTools)
      if (tool.onByDefault) tool.id,
  };

  static final _known = {for (final tool in grantableAgentTools) tool.id};

  final bool _listed;

  /// What the agent was granted to begin with. Ids this build does not know
  /// stay, so a save keeps what a newer build's list named.
  final Set<String> initial;
  final Set<String> _on;

  bool isOn(AgentTool tool) => _on.contains(tool.id);

  bool get changed => _on.length != initial.length || !_on.containsAll(initial);

  void set(AgentTool tool, bool on) {
    if (on) {
      _on.removeAll([
        for (final other in grantableAgentTools)
          if (other.name == tool.name) other.id,
      ]);
      _on.add(tool.id);
    } else {
      _on.remove(tool.id);
    }
  }

  /// On is every name in [group] on in one of its forms.
  bool groupOn(ToolGroup group) {
    final tools = _of(group);
    return tools.every(
      (tool) => tools.any(
        (other) => other.name == tool.name && _on.contains(other.id),
      ),
    );
  }

  /// Switching a group on picks each name's first form.
  void setGroup(ToolGroup group, bool on) {
    final tools = _of(group);
    _on.removeAll(tools.map((tool) => tool.id));
    if (!on) return;
    final names = <String>{};
    for (final tool in tools) {
      if (names.add(tool.name)) _on.add(tool.id);
    }
  }

  static List<AgentTool> _of(ToolGroup group) => [
    for (final tool in grantableAgentTools)
      if (tool.group == group) tool,
  ];

  /// What the file's list becomes. An agent left at the defaults writes no
  /// list, so a default added later reaches it.
  Set<String>? get written => !_listed && !changed
      ? null
      : {
          for (final tool in grantableAgentTools)
            if (_on.contains(tool.id)) tool.id,
          ..._on.difference(_known),
        };
}
