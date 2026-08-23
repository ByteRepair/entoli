import "../../../domain/sync/lan_signaling.dart";

/// A browser cannot listen: there is no socket to bind and no port to put in
/// a QR. Web devices pair as joiners — over a relay or by pasting blobs —
/// which is also why `createLanSignaling` answers null here.
LanSignaling? createWebLanSignaling() => null;
