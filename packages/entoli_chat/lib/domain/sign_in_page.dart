/// The in-app browser a CLI's sign-in page was opened in, which the app
/// closes once the program has exited: the page is done with then, and the
/// user would otherwise have to close it to see what came of it.
abstract interface class SignInPages {
  Future<void> close();
}

/// Where the page opened in another app, which cannot be closed from here.
class NoSignInPages implements SignInPages {
  const NoSignInPages();

  @override
  Future<void> close() async {}
}
