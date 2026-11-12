import "dart:async";

import "package:flutter/foundation.dart" show Listenable;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart"
    show ProviderListenable, ProviderOrFamily;

import "../../app/settings/spec.dart" show SettingReader;

/// A widget's `ref.watch` without a widget: a pass reads through it, and a
/// change to anything the pass watched runs [onChange] once, after the
/// current microtask. What the shell publishes for the open chat is built
/// this way, so it is sent while the Flutter view is out of the window and
/// no frame comes. Each pass re-watches what it reads and lets go of what it
/// no longer does.
class TrackingReader implements SettingReader {
  TrackingReader(this._container, this._onChange);

  final ProviderContainer _container;
  final void Function() _onChange;

  var _watching = <ProviderSubscription<Object?>>[];
  var _pass = <ProviderSubscription<Object?>>[];
  final _listening = <Listenable>[];
  bool _queued = false;
  bool _closed = false;

  /// Runs [build] as one pass: what it watches is what the next change is
  /// heard from.
  T pass<T>(T Function() build) {
    _pass = [];
    try {
      return build();
    } finally {
      for (final old in _watching) {
        old.close();
      }
      _watching = _pass;
    }
  }

  /// Hears [listenable] too, for as long as this reader is open: a model
  /// that is not a provider.
  void listen(Listenable listenable) {
    listenable.addListener(_changed);
    _listening.add(listenable);
  }

  void _changed() {
    if (_queued || _closed) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (!_closed) _onChange();
    });
  }

  @override
  T watch<T>(ProviderListenable<T> provider) {
    final sub = _container.listen<T>(provider, (_, _) => _changed());
    _pass.add(sub);
    return sub.read();
  }

  @override
  T read<T>(ProviderListenable<T> provider) => _container.read(provider);

  @override
  void invalidate(ProviderOrFamily provider) {
    if (!_closed) _container.invalidate(provider);
  }

  void close() {
    _closed = true;
    for (final sub in [..._watching, ..._pass]) {
      sub.close();
    }
    for (final l in _listening) {
      l.removeListener(_changed);
    }
    _listening.clear();
  }
}
