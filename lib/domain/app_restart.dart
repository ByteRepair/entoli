/// Building the app again from what is on disk: a new container over a freshly
/// read data directory, and the old one thrown away.
///
/// A restore replaces the files under a running app, and the app is full of
/// things read out of them exactly once — the settings served from memory, the
/// prompt library built at startup, a live session per chat, the store's idea
/// of which project each chat is in. Telling each holder to look again is a
/// list that has to grow every time something else is read at startup, and one
/// that is silently wrong when it does not. Building the app again is the same
/// answer a restart gives and cannot be left half-done.
///
/// Nothing in Flutter re-runs `main`: hot restart is the VM's, and only where
/// there is one to ask. `AppRoot` is what implements this — see CLAUDE.md,
/// "Backing it all up".
abstract interface class AppRestart {
  Future<void> restart();
}
