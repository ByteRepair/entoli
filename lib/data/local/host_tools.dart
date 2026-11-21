import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:isolate";
import "dart:typed_data";

import "package:archive/archive_io.dart";
import "package:http/http.dart" as http;
import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../../core/tls.dart";
import "../../domain/documents.dart" show writeBytesThroughRename;
import "file_modes.dart";
import "guest_mounts.dart";
import "host_grep.dart";

/// Runs the guest's `unzip`, `tar`, `wget`, `curl` and recursive `grep`
/// natively, where the emulator would interpret every instruction; see
/// "Tools the host runs" in ios/AGENTS.md.
class HostTools {
  HostTools(this.dir, {required this.mounts, http.Client Function()? client})
    : _client = client ?? tlsClient;

  /// The host side of [guestDir].
  final String dir;

  /// The guest's host-backed directories, asked per request: `/root` changes
  /// with the project.
  final List<GuestMount> Function() mounts;

  final http.Client Function() _client;

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
        answer = await run(
          parts[0],
          parts[1],
          parts.sublist(2),
          abandoned: () => !File(taken).existsSync(),
        );
      }
    } catch (e) {
      logFailure("host-tools", "request $id failed", e);
    }
    await writeBytesThroughRename(
      p.join(callsDir, "$id.res"),
      answer?.encode() ?? utf8.encode("fallback\n"),
    );
    try {
      File(taken).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// [tool] with [args], as the guest ran it from [cwd]; null is the guest's
  /// own tool to run. [abandoned] is the shim having gone, which ends a
  /// download nobody waits for.
  Future<HostAnswer?> run(
    String tool,
    String cwd,
    List<String> args, {
    bool Function()? abandoned,
  }) async => switch (tool) {
    "unzip" => await _inflate(_unzip(cwd, args)),
    "tar" => await _inflate(_tar(cwd, args)),
    // A download is I/O and stays on this isolate.
    "wget" => await _wget(cwd, args)?.fetch(_client(), abandoned ?? _never),
    "curl" => await _curl(cwd, args)?.fetch(_client(), abandoned ?? _never),
    "grep" => await _grep(cwd, args),
    _ => null,
  };

  static bool _never() => false;

  /// Inflating is CPU, so it gets an isolate of its own.
  static Future<HostAnswer?> _inflate(_Extract? job) async =>
      job == null ? null : Isolate.run(job.extract);

  /// A search is CPU too; its mounts go with it, since they change with the
  /// project.
  Future<HostAnswer?> _grep(String cwd, List<String> args) async {
    final mounts = this.mounts();
    final result = await Isolate.run(() => GrepJob.search(cwd, args, mounts));
    return result == null ? null : HostAnswer.bytes(result.code, result.output);
  }

  /// busybox's `wget [-q] [-T secs] -O file URL`; anything else (stdout, no
  /// `-O`, continuing, headers) is the guest's.
  _Fetch? _wget(String cwd, List<String> args) {
    final o = _options(
      args,
      flags: {"q"},
      valued: {"O", "T"},
      long: {"--quiet": "q", "--output-document": "O", "--timeout": "T"},
    );
    if (o == null || o.operands.length != 1) return null;
    final secs = int.tryParse(o.options["T"] ?? "900");
    final target = _target(cwd, o.operands.single, o.options["O"]);
    if (secs == null || target == null) return null;
    return _Fetch(
      uri: target.uri,
      dest: target.dest,
      guestDest: o.options["O"]!,
      curl: false,
      quiet: o.options.containsKey("q"),
      failOnError: true,
      follow: true,
      connectTimeout: Duration(seconds: secs),
      idleTimeout: Duration(seconds: secs),
      retries: 0,
    );
  }

  /// curl's `[-fsSL] [--connect-timeout secs] [--retry n] -o file URL`;
  /// anything else (stdout, a method, headers, a body) is the guest's.
  _Fetch? _curl(String cwd, List<String> args) {
    final o = _options(
      args,
      flags: {"f", "s", "S", "L"},
      valued: {"o", "connect-timeout", "retry"},
      long: {
        "--fail": "f",
        "--silent": "s",
        "--show-error": "S",
        "--location": "L",
        "--output": "o",
        "--connect-timeout": "connect-timeout",
        "--retry": "retry",
      },
    );
    if (o == null || o.operands.length != 1) return null;
    final secs = double.tryParse(o.options["connect-timeout"] ?? "300");
    final retries = int.tryParse(o.options["retry"] ?? "0");
    final target = _target(cwd, o.operands.single, o.options["o"]);
    if (secs == null || retries == null || target == null) return null;
    bool has(String flag) => o.options.containsKey(flag);
    return _Fetch(
      uri: target.uri,
      dest: target.dest,
      guestDest: o.options["o"]!,
      curl: true,
      quiet: has("s") && !has("S"),
      failOnError: has("f"),
      follow: has("L"),
      connectTimeout: Duration(milliseconds: (secs * 1000).round()),
      // curl has no idle limit of its own; a stalled transfer is what the
      // command's own timeout ends.
      idleTimeout: const Duration(minutes: 10),
      retries: retries,
    );
  }

  /// [url] and where [out] is on the host, or null where the URL is no plain
  /// http(s) one, [out] is stdout, or it is not where the host can write it:
  /// off the mounts, or in a directory the host does not have.
  ({Uri uri, String dest})? _target(String cwd, String url, String? out) {
    if (out == null || out == "-") return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme("http") || uri.isScheme("https"))) {
      return null;
    }
    final dest = _host(cwd, out);
    if (dest == null || !Directory(p.dirname(dest)).existsSync()) return null;
    return (uri: uri, dest: dest);
  }

  _Extract? _unzip(String cwd, List<String> args) {
    final o = _options(args, flags: {"q", "o"}, valued: {"d"});
    // Members named, or none at all: the guest's tool.
    if (o == null || o.operands.length != 1) return null;
    final archive = _host(cwd, o.operands.single);
    final dest = _host(cwd, o.options["d"] ?? ".");
    if (archive == null || dest == null) return null;
    return _Extract(
      archive: archive,
      guestArchive: o.operands.single,
      dest: dest,
      kind: _ArchiveKind.zip,
      verbose: !o.options.containsKey("q"),
      overwrite: o.options.containsKey("o"),
    );
  }

  _Extract? _tar(String cwd, List<String> args) {
    final words = [...args];
    // The first word may be bundled flags with no dash: `tar xzf a.tgz`.
    if (words.isNotEmpty && !words.first.startsWith("-")) {
      words[0] = "-${words.first}";
    }
    final o = _options(
      words,
      flags: {"x", "v", "o", "p", "z", "j", "J"},
      valued: {"f", "C"},
      long: {"--directory": "C", "--file": "f"},
    );
    // A member named is the guest's tool's.
    if (o == null || o.operands.isNotEmpty || !o.options.containsKey("x")) {
      return null;
    }
    final file = o.options["f"];
    if (file == null || file == "-") return null;
    final archive = _host(cwd, file);
    final dest = _host(cwd, o.options["C"] ?? ".");
    if (archive == null || dest == null) return null;
    final kind = o.options.containsKey("z")
        ? _ArchiveKind.tarGz
        : o.options.containsKey("j")
        ? _ArchiveKind.tarBz2
        : o.options.containsKey("J")
        ? _ArchiveKind.tarXz
        : _sniff(archive);
    return _Extract(
      archive: archive,
      guestArchive: file,
      dest: dest,
      kind: kind,
      verbose: o.options.containsKey("v"),
      overwrite: true,
    );
  }

  /// [args] read getopt's way: short [flags] bundled, a [valued] one taking
  /// the rest of its word or the next, and [long] options named for the key
  /// they set, `--name=value` or `--name value`. Each option is its key, `""`
  /// for a flag; null on anything else, which is the guest's tool's.
  static ({Map<String, String> options, List<String> operands})? _options(
    List<String> args, {
    required Set<String> flags,
    required Set<String> valued,
    Map<String, String> long = const {},
  }) {
    final options = <String, String>{};
    final operands = <String>[];
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String? next() => ++i < args.length ? args[i] : null;
      if (arg.startsWith("--")) {
        final eq = arg.indexOf("=");
        final key = long[eq < 0 ? arg : arg.substring(0, eq)];
        if (key == null) return null;
        final String? value;
        if (valued.contains(key)) {
          value = eq < 0 ? next() : arg.substring(eq + 1);
        } else {
          value = eq < 0 ? "" : null;
        }
        if (value == null) return null;
        options[key] = value;
      } else if (arg.startsWith("-") && arg.length > 1) {
        for (var j = 1; j < arg.length; j++) {
          final key = arg[j];
          if (valued.contains(key)) {
            final value = j + 1 < arg.length ? arg.substring(j + 1) : next();
            if (value == null) return null;
            options[key] = value;
            break;
          }
          if (!flags.contains(key)) return null;
          options[key] = "";
        }
      } else {
        operands.add(arg);
      }
    }
    return (options: options, operands: operands);
  }

  /// [path], as the guest wrote it from [cwd], on the host; null where it
  /// is not under a [GuestMount], the longest mount winning as the guest's
  /// lookup does.
  String? _host(String cwd, String path) =>
      hostPathOf(mounts(), guestPathOf(cwd, path));

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

  static const _tools = ["unzip", "tar", "wget", "curl", "grep"];

  /// What the system prompt says of [_tools]: grep is the one an agent
  /// would otherwise reach past.
  static const promptNote =
      "grep -r runs natively, so search with it rather than rg or a find "
      "piped to grep";

  /// Each of [_tools], by its own name: leaves its call in `calls/` and waits,
  /// or runs the guest's copy where the app falls back or never answers.
  static const _shim = r'''#!/bin/sh
tool=${0##*/}
here=${0%/*}
calls=${here%/*}/calls

# The guest's own tool: the first on PATH that is not this directory.
own=
IFS=:
for d in $PATH; do
  [ "$d" = "$here" ] && continue
  [ -x "$d/$tool" ] && { own=$d/$tool; break; }
done
unset IFS
fallback() {
  [ -n "$own" ] && exec "$own" "$@"
  exec busybox "$tool" "$@"
}

[ -d "$calls" ] || fallback "$@"
if [ "$tool" = grep ]; then
  # Only a recursive search of a directory, decided here: a request costs
  # more than a grep of a pipe or a file. And only busybox's, the grep the
  # host mimics.
  rec= dir= opts=1
  for a; do
    [ "$a" = -- ] && opts=
    case $opts$a in 1--*) ;; 1-*[rR]*) rec=1 ;; esac
    [ -d "$a" ] && dir=1
  done
  [ -n "$rec" ] && [ -n "$dir" ] || fallback "$@"
  case $own in
    '') ;;
    *) case $(readlink "$own") in */busybox | busybox) ;; *) fallback "$@" ;; esac ;;
  esac
fi
req="$calls/$$.$(date +%s)"
printf '%s\0' "$tool" "$PWD" "$@" > "$req.tmp" && mv "$req.tmp" "$req.req" ||
  fallback "$@"
# The claim gone is how the host hears it is waited for no longer.
trap 'rm -f "$req.req" "$req.taken" "$req.res"; exit 130' INT TERM

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
  HostAnswer(this.code, String output) : bytes = utf8.encode(output);

  /// Output that is the files' own bytes, which need not be UTF-8.
  const HostAnswer.bytes(this.code, this.bytes);

  final int code;
  final List<int> bytes;

  String get output => utf8.decode(bytes, allowMalformed: true);

  /// As the shim reads it: the first line, then the output.
  Uint8List encode() {
    final head = utf8.encode("exit $code\n");
    return Uint8List(head.length + bytes.length)
      ..setAll(0, head)
      ..setAll(head.length, bytes);
  }
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

/// One download to a host path, as wget or curl would have made it.
class _Fetch {
  const _Fetch({
    required this.uri,
    required this.dest,
    required this.guestDest,
    required this.curl,
    required this.quiet,
    required this.failOnError,
    required this.follow,
    required this.connectTimeout,
    required this.idleTimeout,
    required this.retries,
  });

  final Uri uri;
  final String dest;
  final String guestDest;
  final bool curl;
  final bool quiet;
  final bool failOnError;
  final bool follow;
  final Duration connectTimeout;
  final Duration idleTimeout;
  final int retries;

  /// [client] is this fetch's, closed when it ends.
  Future<HostAnswer> fetch(
    http.Client client,
    bool Function() abandoned,
  ) async {
    try {
      // A transfer that failed on the network is retried; an HTTP error or
      // a finished one is the answer.
      for (var attempt = 0; attempt <= retries; attempt++) {
        final answer = await _once(client, abandoned);
        if (answer != null) return answer;
      }
      return _failed(curl ? 7 : 1, "can't connect to remote host");
    } finally {
      client.close();
    }
  }

  /// Null is a network failure worth retrying.
  Future<HostAnswer?> _once(
    http.Client client,
    bool Function() abandoned,
  ) async {
    final request = http.Request("GET", uri)
      ..followRedirects = follow
      ..maxRedirects = 20;
    final http.StreamedResponse response;
    try {
      response = await client.send(request).timeout(connectTimeout);
    } catch (e) {
      if (e is TimeoutException ||
          e is SocketException ||
          e is http.ClientException) {
        return null;
      }
      rethrow;
    }
    if (response.statusCode >= 400 && failOnError) {
      await response.stream.drain<void>().catchError((_) {});
      return curl
          ? _failed(
              22,
              "The requested URL returned error: ${response.statusCode}",
            )
          : _failed(
              1,
              "server returned error: HTTP/1.1 ${response.statusCode} "
                      "${response.reasonPhrase ?? ""}"
                  .trimRight(),
            );
    }
    final file = File(dest);
    final sink = file.openWrite();
    var received = 0;
    var stopped = false;
    // A stat a second rather than a chunk: this is the UI isolate.
    final sinceCheck = Stopwatch();
    try {
      // addStream for its backpressure: a network faster than the flash
      // would otherwise queue the gap on the heap.
      await sink.addStream(
        response.stream.timeout(idleTimeout).takeWhile((chunk) {
          if (!sinceCheck.isRunning ||
              sinceCheck.elapsed > const Duration(seconds: 1)) {
            sinceCheck
              ..reset()
              ..start();
            stopped = abandoned();
          }
          received += chunk.length;
          return !stopped;
        }),
      );
      await sink.close();
    } catch (e) {
      await sink.close().catchError((_) {});
      _delete(file);
      if (e is TimeoutException) {
        return _failed(
          curl ? 28 : 1,
          curl ? "Operation timed out" : "download timed out",
        );
      }
      return null;
    }
    if (stopped) {
      _delete(file);
      return const HostAnswer.bytes(130, []);
    }
    // Shorter than declared is a connection dropped, not a finished file.
    final expected = response.contentLength;
    if (expected != null && received != expected) {
      _delete(file);
      return null;
    }
    return HostAnswer(
      0,
      quiet || curl
          ? ""
          : "Connecting to ${uri.host}\nsaving to '$guestDest'\n"
                "'$guestDest' saved\n",
    );
  }

  static void _delete(File file) {
    try {
      file.deleteSync();
    } on FileSystemException {
      // Never made.
    }
  }

  HostAnswer _failed(int code, String why) => HostAnswer(
    code,
    quiet ? "" : (curl ? "curl: ($code) $why\n" : "wget: $why\n"),
  );
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
    // The guest's tool says what is missing, in its own words.
    if (!File(archive).existsSync()) return null;
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
