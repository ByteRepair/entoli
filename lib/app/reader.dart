import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart"
    show ProviderListenable, ProviderOrFamily;

/// What the core reads the rest of the app through, so a model built in a
/// widget's build reads through that widget's ref. [watch] rebuilds the
/// reader's owner on a change.
abstract interface class SettingReader {
  T watch<T>(ProviderListenable<T> provider);

  T read<T>(ProviderListenable<T> provider);

  /// Has [provider] asked again, where what it answered has changed under it.
  /// Nothing where the reader's owner is gone, as it may be by the time an
  /// action's await returns.
  void invalidate(ProviderOrFamily provider);
}

/// A widget's [WidgetRef] as a [SettingReader].
final class WidgetReader implements SettingReader {
  const WidgetReader(this.ref);

  final WidgetRef ref;

  @override
  T watch<T>(ProviderListenable<T> provider) => ref.watch(provider);

  @override
  T read<T>(ProviderListenable<T> provider) => ref.read(provider);

  @override
  void invalidate(ProviderOrFamily provider) {
    if (ref.context.mounted) ref.invalidate(provider);
  }
}
