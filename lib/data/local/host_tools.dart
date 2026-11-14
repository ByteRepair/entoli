import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:isolate";

import "package:archive/archive_io.dart";
import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../../domain/documents.dart" show writeThroughRename;
import "file_modes.dart";

/// A guest directory that is a host one: what the guest calls [guest] is
/// [host] on the host's disk.
typedef GuestMount = ({String guest, String host});

/// Runs the guest's `unzip` and `tar` natively, where the emulator would
/// interpret every instruction; see "Tools the host runs" in ios/AGENTS.md.
class HostTools {
  HostTools(this.dir, {required this.mounts});

  /// The host side of [guestDir].
  final String dir;

  /// The guest's host-backed directories, asked per request: `/root` changes
  /// with the project.
  final List<GuestMount> Function() mounts;

  static const guestDir = "/run/entoli";
  static const guestBin = "$guestDir/bin";

  String get binDir => p.join(dir, "bin");
  String get callsDir => p.join(dir, "calls");

  Timer? _poll;
  int _holds = 0;

  /// Writes the shims and an empty calls directory: a request left from a
  /// run that died is nobody's now.
  void install() {
    Directory(binDir).createSync(recursive: true);
    final calls = Directory(callsDir);
    if (calls.existsSync()) calls.deleteSync(recursive: true);
    calls.createSync(recursive: true);
    for (final tool in _tools) {
      final file = File(p.join(binDir, tool))..writeAsStringSync(_shim);
      makeExecutable(file.path);
    }
  }

  /// Answers requests until [done]: only a guest command can make one, so
  /// nothing is polled while none runs.
  void hold(Future<void> done) {
    _holds++;
    start();
    // The run's own failure is its caller's to see, not this one's.
    unawaited(
      done.then((_) {}, onError: (Object _) {}).whenComplete(() {
        if (--_holds == 0) stop();
      }),
    );
  }

  void start() {
    _poll ??= Timer.periodic(const Duration(milliseconds: 100), (_) => _scan());
  }

  void stop() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _scan() async {
    try {
      await for (final entry in Directory(callsDir).list()) {
        if (entry.path.endsWith(".req")) unawaited(_serve(entry.path));
      }
    } on FileSystemException {
      // Not there yet, or gone; the next scan looks again.
    }
  }

  /// Renaming the request is the claim, and tells the shim it is taken.
  Future<void> _serve(String request) async {
    final id = p.basenameWithoutExtension(request);
    final taken = p.join(callsDir, "$id.taken");
    try {
      File(request).renameSync(taken);
    } on FileSystemException {
      return;
    }
    HostAnswer? answer;
    try {
      final parts = utf8.decode(File(taken).readAsBytesSync()).split("\x00");
      if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
      if (parts.length >= 2) {
        answer = await run(parts[0], parts[1], parts.sublist(2));
      }
    } catch (e) {
      logFailure("host-tools", "request $id failed", e);
    }
    await writeThroughRename(
      p.join(callsDir, "$id.res"),
      answer?.encode() ?? "fallback\n",
    );
    try {
      File(taken).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// [tool] with [args], as the guest ran it from [cwd]; null is the guest's
  /// own tool to run.
  Future<HostAnswer?> run(String tool, String cwd, List<String> args) async {
    final job = switch (tool) {
      "unzip" => _unzip(cwd, args),
      "tar" => _tar(cwd, args),
      _ => null,
    };
    return job == null ? null : Isolate.run(job.extract);
  }

  _Extract? _unzip(String cwd, List<String> args) {
    var quiet = false;
    var overwrite = false;
    String? into;
    final positional = <String>[];
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == "-d") {
        if (++i >= args.length) return null;
        into = args[i];
      } else if (arg.startsWith("-d") && arg.length > 2) {
        into = arg.substring(2);
      } else if (arg.startsWith("-") && arg.length > 1) {
        for (final flag in arg.substring(1).split("")) {
          switch (flag) {
            case "q":
              quiet = true;
            case "o":
              overwrite = true;
            default:
              return null;
          }
        }
      } else {
        positional.add(arg);
      }
    }
    // Members named, or none at all: the guest's tool.
    if (positional.length != 1) return null;
    final archive = _host(cwd, positional.single);
    final dest = _host(cwd, into ?? ".");
    if (archive == null || dest == null) return null;
    return _Extract(
      archive: archive,
      guestArchive: positional.single,
      dest: dest,
      kind: _ArchiveKind.zip,
      verbose: !quiet,
      overwrite: overwrite,
    );
  }

  _Extract? _tar(String cwd, List<String> args) {
    var extract = false;
    var verbose = false;
    _ArchiveKind? kind;
    String? file;
    String? into;
    final rest = [...args];
    // The first word may be bundled flags with no dash: `tar xzf a.tgz`.
    if (rest.isNotEmpty && !rest.first.startsWith("-")) {
      rest[0] = "-${rest.first}";
    }
    for (var i = 0; i < rest.length; i++) {
      final arg = rest[i];
      if (arg.startsWith("--directory=")) {
        into = arg.substring("--directory=".length);
      } else if (arg.startsWith("--file=")) {
        file = arg.substring("--file=".length);
      } else if (arg.startsWith("--")) {
        return null;
      } else if (arg.startsWith("-") && arg.length > 1) {
        final flags = arg.substring(1);
        for (var j = 0; j < flags.length; j++) {
          switch (flags[j]) {
            case "x":
              extract = true;
            case "v":
              verbose = true;
            case "o" || "p":
              break;
            case "z":
              kind = _ArchiveKind.tarGz;
            case "j":
              kind = _ArchiveKind.tarBz2;
            case "J":
              kind = _ArchiveKind.tarXz;
            case "f" || "C":
              // Its value is the rest of this word, or the next one.
              final value = j + 1 < flags.length
                  ? flags.substring(j + 1)
                  : (++i < rest.length ? rest[i] : null);
              if (value == null) return null;
              flags[j] == "f" ? file = value : into = value;
              j = flags.length;
            default:
              return null;
          }
        }
      } else {
        // A member named: the guest's tool.
        return null;
      }
    }
    if (!extract || file == null || file == "-") return null;
    final archive = _host(cwd, file);
    final dest = _host(cwd, into ?? ".");
    if (archive == null || dest == null) return null;
    return _Extract(
      archive: archive,
      guestArchive: file,
      dest: dest,
      kind: kind ?? _sniff(archive),
      verbose: verbose,
      overwrite: true,
    );
  }

  /// [path], as the guest wrote it from [cwd], on the host; null where it
  /// is not under a [GuestMount], the longest mount winning as the guest's
  /// lookup does.
  String? _host(String cwd, String path) {
    final guest = p.posix.normalize(p.posix.join(cwd, path));
    GuestMount? best;
    for (final mount in mounts()) {
      if (guest == mount.guest || p.posix.isWithin(mount.guest, guest)) {
        if (best == null || mount.guest.length > best.guest.length) {
          best = mount;
        }
      }
    }
    if (best == null) return null;
    final relative = p.posix.relative(guest, from: best.guest);
    return relative == "." ? best.host : p.join(best.host, relative);
  }

  /// A tar given no compression flag is what its first bytes say, as
  /// busybox's tar decides.
  static _ArchiveKind _sniff(String path) {
    final head = File(path).openSync();
    try {
      final b = head.readSync(6);
      if (b.length >= 2 && b[0] == 0x1f && b[1] == 0x8b) {
        return _ArchiveKind.tarGz;
      }
      if (b.length >= 3 && b[0] == 0x42 && b[1] == 0x5a && b[2] == 0x68) {
        return _ArchiveKind.tarBz2;
      }
      if (b.length >= 6 && b[0] == 0xfd && b[1] == 0x37 && b[2] == 0x7a) {
        return _ArchiveKind.tarXz;
      }
      return _ArchiveKind.tar;
    } finally {
      head.closeSync();
    }
  }

  static const _tools = ["unzip", "tar"];

  /// Each of [_tools], by its own name: leaves its call in `calls/` and waits,
  /// or runs the guest's copy where the app falls back or never answers.
  static const _shim = r'''#!/bin/sh
tool=${0##*/}
here=${0%/*}
calls=${here%/*}/calls

fallback() {
  # The guest's own tool: the first on PATH that is not this directory.
  IFS=:
  for d in $PATH; do
    [ "$d" = "$here" ] && continue
    [ -x "$d/$tool" ] && { unset IFS; exec "$d/$tool" "$@"; }
  done
  unset IFS
  exec busybox "$tool" "$@"
}

[ -d "$calls" ] || fallback "$@"
req="$calls/$$.$(date +%s)"
printf '%s\0' "$tool" "$PWD" "$@" > "$req.tmp" && mv "$req.tmp" "$req.req" ||
  fallback "$@"
trap 'rm -f "$req.req" "$req.res"; exit 130' INT TERM

# Taken within four seconds, or the app is not listening.
n=0
while [ -e "$req.req" ]; do
  if [ "$n" -ge 40 ]; then
    rm -f "$req.req"
    fallback "$@"
  fi
  sleep 0.1
  n=$((n + 1))
done
# Each sleep is a process the emulator starts, so a long wait polls slower.
n=0
while [ ! -e "$req.res" ]; do
  if [ "$n" -lt 10 ]; then sleep 0.1; else sleep 1; fi
  n=$((n + 1))
done

read -r first < "$req.res"
case "$first" in
  "exit "*)
    tail -n +2 "$req.res"
    rm -f "$req.res"
    exit "${first#exit }"
    ;;
esac
rm -f "$req.res"
fallback "$@"
''';
}

/// How a tool the host ran ended, and what it printed.
class HostAnswer {
  const HostAnswer(this.code, this.output);

  final int code;
  final String output;

  /// As the shim reads it: the first line, then the output.
  String encode() => "exit $code\n$output";
}

enum _ArchiveKind {
  zip(".zip"),
  tar(".tar"),
  tarGz(".tar.gz"),
  tarBz2(".tar.bz2"),
  tarXz(".tar.xz");

  const _ArchiveKind(this.extension);

  /// What `extractFileToDisk` reads the format from.
  final String extension;
}

/// One extraction, with everything it needs and nothing of the service, so
/// it runs on its own isolate.
class _Extract {
  const _Extract({
    required this.archive,
    required this.guestArchive,
    required this.dest,
    required this.kind,
    required this.verbose,
    required this.overwrite,
  });

  final String archive;
  final String guestArchive;
  final String dest;
  final _ArchiveKind kind;
  final bool verbose;
  final bool overwrite;

  /// Null where the guest's tool should run instead.
  Future<HostAnswer?> extract() async {
    final zip = kind == _ArchiveKind.zip;
    final tool = zip ? "unzip" : "tar";
    if (!File(archive).existsSync()) {
      return HostAnswer(1, "$tool: can't open '$guestArchive'\n");
    }
    // unzip asks before replacing a file, which is the guest's tool's
    // business: only a zip that replaces nothing, or is told to, is ours.
    if (zip && !overwrite) {
      final input = InputFileStream(archive);
      try {
        final names = ZipDecoder().decodeStream(input);
        final clash = names.any(
          (f) => f.isFile && File(p.join(dest, f.name)).existsSync(),
        );
        if (clash) return null;
      } finally {
        await input.close();
      }
    }
    // The format is read off the name, so an archive not named for it is
    // reached through a link that is.
    var source = archive;
    Directory? linked;
    if (!archive.toLowerCase().endsWith(kind.extension)) {
      linked = Directory.systemTemp.createTempSync("host-tools");
      source = p.join(linked.path, "archive${kind.extension}");
      Link(source).createSync(archive);
    }
    final out = StringBuffer();
    // package:archive sets modes only where its posix package loads libc,
    // which it does not on iOS, so each file's are set here once written.
    final modes = <(String, int)>[];
    if (verbose && zip) {
      out.writeln("Archive:  $guestArchive");
    }
    try {
      Directory(dest).createSync(recursive: true);
      await extractFileToDisk(
        source,
        dest,
        callback: (entry) {
          if (entry.isFile && !entry.isSymbolicLink) {
            modes.add((entry.name, entry.unixPermissions));
          }
          if (verbose) {
            out.writeln(zip ? "  inflating: ${entry.name}" : entry.name);
          }
        },
      );
      for (final (name, mode) in modes) {
        final file = p.join(dest, name);
        if (mode != 0 && File(file).existsSync()) setMode(file, mode);
      }
      return HostAnswer(0, out.toString());
    } catch (e) {
      out.writeln("$tool: $e");
      return HostAnswer(1, out.toString());
    } finally {
      linked?.deleteSync(recursive: true);
    }
  }
}
