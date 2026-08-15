import "../../domain/models.dart";
import "io/default_backend.dart"
    if (dart.library.js_interop) "web/default_backend.dart"
    as platform;

/// Platform-default backend: opencode on desktop, the built-in harness
/// everywhere else.
BackendKind defaultBackendKind() => platform.defaultBackendKind();

/// What this platform can run at all. A list of one is a platform with no
/// choice to offer, which is why settings hides the picker there.
List<BackendKind> availableBackendKinds() => platform.availableBackendKinds();
