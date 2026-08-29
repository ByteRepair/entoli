import "package:flutter/foundation.dart" show defaultTargetPlatform, TargetPlatform;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../providers.dart";
import "../widgets/section_header.dart";

/// The Byte Repair category: whether the configured terminal env can run its
/// tooling, a button that installs it, and the ESBMC version found afterwards.
///
/// On Android the "Host" terminal env has no package manager, so the category
/// says so and hides the rest — nothing here can run until a rootfs is picked
/// from the Terminal settings. On every other platform the host shell is the
/// only env and is capable, so the green line shows and the button is there.
class ByteRepairSection extends ConsumerStatefulWidget {
  const ByteRepairSection({super.key});

  @override
  ConsumerState<ByteRepairSection> createState() => _ByteRepairSectionState();
}

class _ByteRepairSectionState extends ConsumerState<ByteRepairSection> {
  bool _running = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rootfsId = ref.watch(appSettingsProvider.select((s) => s.rootfsId));
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final incompatible = isAndroid && rootfsId == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Byte Repair",
          description: "Installs ESBMC and supporting tooling for formal "
              "verification of C code. Runs through the configured terminal "
              "environment, so it needs one with a package manager.",
        ),
        if (incompatible)
          _Banner(
            icon: Icons.warning_amber_rounded,
            color: theme.colorScheme.error,
            text: 'Byte Repair does not work when using the "Host" terminal '
                "environment on this device. Please choose another terminal "
                "environment.",
          )
        else ...[
          _Banner(
            icon: Icons.check_circle_outline,
            color: theme.colorScheme.primary,
            text: "Byte Repair tooling can run with this configuration.",
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _running ? null : _runSetup,
              icon: _running
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_outlined),
              label: const Text("Run Setup"),
            ),
          ),
          if (_running) ...[
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _VersionDisplay(),
        ],
      ],
    );
  }

  Future<void> _runSetup() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final store = ref.read(byteRepairStoreProvider);
      final shell = ref.read(shellProvider);
      final result = await store.install(shell);
      if (!mounted) return;
      if (result.returnCode == 0) {
        ref.invalidate(byteRepairVersionProvider);
      } else {
        setState(() {
          _error = result.exceptionInfo ?? result.output.trim();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _VersionDisplay extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(byteRepairVersionProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: version.when(
        loading: () => const SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        error: (e, st) => Text(
          "Not installed",
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        data: (v) => Text(
          v != null ? "ESBMC $v" : "Not installed",
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}