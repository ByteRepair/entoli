# The camera that reads a pairing code

`entoli_scanner` is the adapter for the camera. `entoli_scanner.dart` is the
whole of it: `PluginCodeScanner` answers the core's `CodeScanner`
(`view/code_scanner.dart`) with `mobile_scanner`, and `main` binds it as
`codeScannerProvider`. The camera view is the plugin, so the widget lives
here and the app's `ScanQrPage` (`lib/ui/settings/sync_pairing.dart`) asks
the provider for it, handing it what to do with a code and what to show in
the camera's place.

The view owns its controller. It reports each non-empty code it reads until
the page's callback takes one, then stops the camera, so a code read twice
in one frame is not popped twice. A refused permission and any other camera
failure are told apart here and drawn by the page: the refused page names
the way back to the permission, which differs per platform (see `ScanQrPage`
and "The pairing flows as pages" in `lib/data/sync/AGENTS.md`).

The permission strings are the app bundle's, not this package's: `CAMERA`
in the Android manifest and `NSCameraUsageDescription` in iOS's
`Info.plist`. macOS links the plugin but never opens the scanner, the button
being on the phones alone.
