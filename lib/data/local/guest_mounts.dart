import "package:path/path.dart" as p;

/// A guest directory that is a host one: what the guest calls [guest] is
/// [host] on the host's disk.
typedef GuestMount = ({String guest, String host});

/// [path], as the guest wrote it from [cwd], as a normalized guest path.
String guestPathOf(String cwd, String path) =>
    p.posix.normalize(p.posix.join(cwd, path));

/// [guest], a normalized absolute guest path, on the host; null where it is
/// not under one of [mounts], the longest winning as the guest's lookup does.
String? hostPathOf(List<GuestMount> mounts, String guest) {
  GuestMount? best;
  for (final mount in mounts) {
    if (guest == mount.guest || p.posix.isWithin(mount.guest, guest)) {
      if (best == null || mount.guest.length > best.guest.length) best = mount;
    }
  }
  if (best == null) return null;
  final relative = p.posix.relative(guest, from: best.guest);
  return relative == "." ? best.host : p.join(best.host, relative);
}
