import "../../domain/models.dart";
import "io/default_backend.dart"
    if (dart.library.js_interop) "web/default_backend.dart"
    as platform;

/// Platform-default backend: opencode on desktop, miniswe everywhere else.
BackendKind defaultBackendKind() => platform.defaultBackendKind();