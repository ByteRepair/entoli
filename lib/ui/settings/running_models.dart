import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/formatting.dart";
import "../../data/local/local_instance.dart" show LocalUsage;
import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../providers.dart";
import "../widgets/section_header.dart";

/// What is loaded right now, at the top of the On-device page: the one thing
/// there that changes without being touched, and the one most often come to
/// for — to see what a model is costing, and to let it go. Loading takes the
/// better part of a minute, nothing here started it, and a model that will
/// not fit says so here and nowhere else.
class RunningModelsSection extends ConsumerWidget {
  const RunningModelsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(localEngineProvider).available) {
      return const SizedBox.shrink();
    }
    final running = ref.watch(localLlmStateProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Header(),
        const _Prefilling(),
        if (running.isEmpty)
          const ListTile(
            title: Text("Nothing loaded"),
            subtitle: Text("The first chat to ask for one loads it."),
          )
        else ...[
          for (final state in running)
            _RunningRow(state, key: ValueKey(state.modelId)),
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: TextButton(
              onPressed: () => ref.read(localEngineProvider).stopAll(),
              child: const Text("Unload all"),
            ),
          ),
        ],
      ],
    );
  }
}

/// The section's title, and under it what the models take up together —
/// the model host's whole footprint on a Mac, where several models share it
/// and the rows cannot say what is between them.
class _Header extends ConsumerStatefulWidget {
  const _Header();

  @override
  ConsumerState<_Header> createState() => _HeaderState();
}

class _HeaderState extends ConsumerState<_Header> {
  int? _total;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
    _timer = Timer.periodic(usageRefresh, (_) => unawaited(_measure()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _measure() async {
    final total = await ref.read(localEngineProvider).totalBytes();
    if (mounted) setState(() => _total = total);
  }

  @override
  Widget build(BuildContext context) {
    final total = _total;
    return SectionHeader(
      "Running models",
      description: total == null ? null : "${formatSize(total)} in memory",
    );
  }
}

/// How often what the models take up is asked again while it is drawn: a
/// model's cache grows as a chat goes on, and this is a place to watch that
/// happen.
const usageRefresh = Duration(seconds: 3);

/// The warm-up in progress, drawn only while there is one — the rest of the
/// time it has nothing to say. Its own row rather than a line on a model's
/// because a model can be warming before any chat has loaded one.
class _Prefilling extends ConsumerWidget {
  const _Prefilling();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localPrefillStateProvider);
    if (state == null) return const SizedBox.shrink();
    final pct = state.fraction == null
        ? ""
        : " · ${(state.fraction! * 100).round()}%";
    return ListTile(
      leading: const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      title: Text("Prefilling ${state.name}…"),
      subtitle: Text(
        "Warming its system prompt so the first chat starts "
        "sooner$pct",
      ),
    );
  }
}

/// One loaded model: where it answers, what it takes up, and its own Unload.
class _RunningRow extends ConsumerStatefulWidget {
  const _RunningRow(this.state, {super.key});

  final LocalLlmState state;

  @override
  ConsumerState<_RunningRow> createState() => _RunningRowState();
}

class _RunningRowState extends ConsumerState<_RunningRow> {
  LocalUsage? _usage;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
    _timer = Timer.periodic(usageRefresh, (_) => unawaited(_measure()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _measure() async {
    final usage = await ref
        .read(localEngineProvider)
        .usage(widget.state.modelId);
    if (mounted) setState(() => _usage = usage);
  }

  /// Where it actually ended up, which is the one thing the picker cannot say:
  /// Auto is resolved when the model loads, and a phone whose accelerator this
  /// build cannot reach answers on the CPU whatever was picked.
  static String? _where(String? device) => switch (device) {
    null => null,
    LocalDevice.cpu => "the CPU",
    final name => "the ${LocalDevice.computeOf(name).label} ($name)",
  };

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final theme = Theme.of(context);
    final name = ref.watch(localEngineProvider).nameOf(state.modelId);
    final where = _where(state.device);
    final usage = _usage;
    // One model let go of, the rest left loaded — and a load still under way
    // or one that failed cleared the same way, so no row is stuck here.
    final stop = IconButton(
      icon: const Icon(Icons.stop_circle_outlined),
      tooltip: "Unload $name",
      onPressed: () => ref.read(localEngineProvider).stop(state.modelId),
    );
    return switch (state.phase) {
      LocalLlmPhase.starting => ListTile(
        leading: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text("Loading $name…"),
        subtitle: const Text("A chat sent before this finishes waits for it."),
        trailing: stop,
      ),
      LocalLlmPhase.ready => ListTile(
        leading: Icon(
          Icons.check_circle_outline,
          color: theme.colorScheme.primary,
        ),
        title: Text(name),
        subtitle: Text(
          [
            where == null ? "Answering" : "Answering on $where",
            if (state.contextLength case final context?)
              "${tokenCount(context)} tokens of context",
            if (usage != null) "${formatSize(usage.bytes)} in memory",
            if (usage?.tokens case final tokens? when tokens > 0)
              "${tokenCount(tokens)} tokens cached",
          ].join(" · "),
        ),
        trailing: stop,
      ),
      LocalLlmPhase.failed => ListTile(
        isThreeLine: true,
        leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
        title: Text("$name would not load"),
        subtitle: Text(
          state.failure ?? "",
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        trailing: stop,
      ),
    };
  }
}
