import "dart:async";

import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/agent_browser.dart";
import "../../domain/download.dart";
import "../../providers.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "downloads.dart";

/// The one thing [Downloads] holds here: the embedded browser, Helium. It
/// replaces the copy the running browser was started from, so that one is
/// quit first.
class EmbeddedBrowserDownloads extends Downloads<String> {
  static const id = "helium";

  @override
  String idOf(String item) => item;

  @override
  Download? begin(String item) {
    final browser = ref.read(agentBrowserProvider);
    Stream<DownloadProgress> install() async* {
      await browser.close();
      yield* browser.embedded.install();
    }

    return Download(bytes: 0, progress: install());
  }

  @override
  String nameOf(String item) => "Helium";

  @override
  String get plural => "browsers";

  /// A first download with nothing picked yet is the pick: it is what the
  /// button was pressed for.
  @override
  Future<void> rescan() async {
    final settings = ref.read(appSettingsProvider);
    if (settings.agentBrowser == null &&
        ref.read(agentBrowserProvider).embedded.installedVersion != null) {
      await ref
          .read(appSettingsProvider.notifier)
          .setAgentBrowser(embeddedBrowserId);
    }
  }

  @override
  Future<void> unpick(String item) async {
    await ref.read(agentBrowserProvider).close();
    if (ref.read(appSettingsProvider).agentBrowser == embeddedBrowserId) {
      await ref.read(appSettingsProvider.notifier).setAgentBrowser(null);
    }
  }

  @override
  Future<void> erase(String item) =>
      ref.read(agentBrowserProvider).embedded.remove();
}

final embeddedBrowserDownloadsProvider =
    NotifierProvider<EmbeddedBrowserDownloads, DownloadState>(
        EmbeddedBrowserDownloads.new);

/// Settings > Agent Browser: which browser the `browser_*` tools drive, and
/// the embedded one to download. Drawn only where [AgentBrowser.available].
class AgentBrowserSection extends ConsumerStatefulWidget {
  const AgentBrowserSection({super.key});

  @override
  ConsumerState<AgentBrowserSection> createState() =>
      _AgentBrowserSectionState();
}

/// The dropdown's entry that opens the file picker rather than picking.
const _choose = "\u0000choose";

class _AgentBrowserSectionState extends ConsumerState<AgentBrowserSection> {
  late final Future<List<FoundBrowser>> _found =
      ref.read(agentBrowserProvider).detect();
  bool _verifying = false;
  String? _problem;

  Future<void> _pick(String? value) async {
    if (value != _choose) {
      setState(() => _problem = null);
      await ref.read(appSettingsProvider.notifier).setAgentBrowser(value);
      return;
    }
    final file = await openFile(confirmButtonText: "Use this browser");
    if (file == null) return;
    setState(() {
      _verifying = true;
      _problem = null;
    });
    try {
      final exe = await ref.read(agentBrowserProvider).verify(file.path);
      await ref.read(appSettingsProvider.notifier).setAgentBrowser(exe);
    } catch (e) {
      if (mounted) setState(() => _problem = "$e");
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final browser = ref.watch(agentBrowserProvider);
    final picked = ref.watch(appSettingsProvider).agentBrowser;
    final downloads = ref.watch(embeddedBrowserDownloadsProvider);
    final embedded = browser.embedded;
    final installed = embedded.installedVersion;
    final progress = downloads.active[EmbeddedBrowserDownloads.id];
    final failure = downloads.failures[EmbeddedBrowserDownloads.id];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Agent browser",
          description: "A browser window the agent opens pages in, clicks and "
              "types into, for pages that need JavaScript or a login. It runs "
              "with a profile of its own, so what it logs into stays logged in "
              "and your own browser's profile is never touched.",
        ),
        FutureBuilder<List<FoundBrowser>>(
          future: _found,
          builder: (context, snapshot) {
            final found = snapshot.data ?? const <FoundBrowser>[];
            final custom = picked != null &&
                picked != embeddedBrowserId &&
                !found.any((b) => b.path == picked);
            return LabelledField(
              label: "Browser",
              child: DropdownButtonFormField<String?>(
                key: ValueKey(picked),
                initialValue: picked == embeddedBrowserId && installed == null
                    ? null
                    : picked,
                isExpanded: true,
                decoration: InputDecoration(
                  helperText: _verifying
                      ? "Starting it to check it can be driven…"
                      : picked == null
                          ? "Off: the agent has no browser tools."
                          : "Only Chromium-family browsers can be driven.",
                  errorText: _problem,
                  errorMaxLines: 4,
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text("Off")),
                  if (installed != null)
                    DropdownMenuItem(
                      value: embeddedBrowserId,
                      child: Text("Embedded (Helium $installed)"),
                    ),
                  for (final found in found)
                    DropdownMenuItem(value: found.path, child: Text(found.name)),
                  if (custom)
                    DropdownMenuItem(
                      value: picked,
                      child: Text(picked, overflow: TextOverflow.ellipsis),
                    ),
                  const DropdownMenuItem(
                    value: _choose,
                    child: Text("Choose a browser…"),
                  ),
                ],
                onChanged: _verifying ? null : (value) => unawaited(_pick(value)),
              ),
            );
          },
        ),
        const Divider(),
        const SectionHeader(
          "Embedded browser",
          description: "Helium, a Chromium browser that ships with uBlock "
              "Origin: the pages the agent opens come without ads or "
              "trackers, and with fewer scripts that try to talk it into "
              "something. Downloaded from Helium's GitHub releases.",
        ),
        ListTile(
          title: const Text("Helium"),
          subtitle: progress != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(progress.unpacking
                        ? "Installing…"
                        : progress.total > 0
                            ? "Downloading · ${progress.received >> 20} of "
                                "${progress.total >> 20} MB"
                            : "Downloading…"),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                        value: progress.unpacking ? null : progress.fraction),
                  ],
                )
              : Text(failure ??
                  (installed == null ? "Not downloaded" : "Version $installed")),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (progress != null)
                TextButton(
                  onPressed: () => ref
                      .read(embeddedBrowserDownloadsProvider.notifier)
                      .cancel(EmbeddedBrowserDownloads.id),
                  child: const Text("Cancel"),
                )
              else ...[
                if (installed != null)
                  IconButton(
                    tooltip: "Delete",
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => unawaited(ref
                        .read(embeddedBrowserDownloadsProvider.notifier)
                        .delete(EmbeddedBrowserDownloads.id)),
                  ),
                FilledButton.tonal(
                  onPressed: () => ref
                      .read(embeddedBrowserDownloadsProvider.notifier)
                      .install(EmbeddedBrowserDownloads.id),
                  child: Text(installed == null ? "Download" : "Update"),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
