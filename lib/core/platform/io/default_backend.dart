import "dart:io";

import "../../../domain/models.dart";

bool get _mobile => Platform.isAndroid || Platform.isIOS;

BackendKind defaultBackendKind() =>
    _mobile ? BackendKind.miniswe : BackendKind.opencode;

/// Only desktop has a choice: there is no opencode binary to spawn on a phone.
List<BackendKind> availableBackendKinds() =>
    _mobile ? const [BackendKind.miniswe] : BackendKind.values;
