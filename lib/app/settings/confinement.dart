import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:entoli_chat/domain/confinement.dart";
import "../../providers.dart";

/// What the picked driver does about the sandbox: the environment's own
/// answer, with nothing installed falling back to the host's.
final pickedConfinementProvider = Provider<Confinement>((ref) {
  final selected = ref.watch(appSettingsProvider.select((s) => s.rootfsId));
  final installed = ref.watch(installedRootfsProvider);
  return selected == null || !installed.contains(selected)
      ? ref.watch(hostConfinementProvider)
      : Confinement.guest;
});
