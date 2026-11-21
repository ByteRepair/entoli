import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/local/guest_mounts.dart";
import "package:agent_chat/data/local/host_grep.dart";

import "../../harness.dart" show tempDir;

/// What each search prints is busybox 1.37's own, recorded from the x86-64
/// Alpine guest over the same files.
void main() {
  late String workspace;
  late List<GuestMount> mounts;

  setUp(() {
    workspace = tempDir("host-grep-test").resolveSymbolicLinksSync();
    mounts = [(guest: "/root", host: workspace)];
  });

  void write(String path, List<int> bytes) {
    final file = File(p.join(workspace, path));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  ({int code, String output})? grep(List<String> args) {
    final result = GrepJob.search("/root", args, mounts);
    if (result == null) return null;
    return (code: result.code, output: latin1.decode(result.output));
  }

  test("context lines and the separator between them", () {
    write("ctx/f", utf8.encode("one\nx two\nthree\nfour\nfive x\nsix\n"));

    expect(grep(["-rn", "-A1", "-B1", "x", "ctx"]), (
      code: 0,
      output:
          "ctx/f-1-one\nctx/f:2:x two\nctx/f-3-three\nctx/f-4-four\n"
          "ctx/f:5:five x\nctx/f:6:six\n",
    ));
    expect(grep(["-rh", "-m1", "x", "ctx"]), (code: 0, output: "x two\n"));
  });

  test("a NUL ends a line, as busybox reads them", () {
    write("nul/f", [...utf8.encode("xa"), 0, ...utf8.encode("yb\nzc")]);

    expect(grep(["-rn", "yb", "nul"]), (code: 0, output: "nul/f:2:yb\n"));
    expect(grep(["-rc", ".", "nul"]), (code: 0, output: "nul/f:3\n"));
  });

  test("a regex reads a line only as far as musl decodes it", () {
    write("bad/f", [0x61, 0x62, 0xff, 0x63, 0x64, 0x0a, 0x61, 0x62, 0x0a]);

    // "ab" ends where regexec would read the invalid byte; "a" does not.
    expect(grep(["-rn", "ab", "bad"]), (code: 0, output: "bad/f:2:ab\n"));
    expect(grep(["-rn", "a", "bad"]), (
      code: 0,
      output: "bad/f:1:ab\xffcd\nbad/f:2:ab\n",
    ));
    // -F is strstr, on the bytes.
    expect(grep(["-rniF", "AB", "bad"]), (
      code: 0,
      output: "bad/f:1:ab\xffcd\nbad/f:2:ab\n",
    ));
  });

  test("BRE and ERE alternation", () {
    write("re/f", utf8.encode("a|b\nb\n"));

    expect(grep(["-rn", r"a\|b", "re"]), (
      code: 0,
      output: "re/f:1:a|b\nre/f:2:b\n",
    ));
    expect(grep(["-rn", "a|b", "re"]), (code: 0, output: "re/f:1:a|b\n"));
    expect(grep(["-rnE", "a|b", "re"]), (
      code: 0,
      output: "re/f:1:a|b\nre/f:2:b\n",
    ));
  });

  test("-w retries past a match a word character touches", () {
    write("w/f", utf8.encode("foobar\nfoobar foo\nfoo_bar\n"));

    expect(grep(["-rnw", "foo", "w"]), (code: 0, output: "w/f:2:foobar foo\n"));
  });

  test("-i folds ASCII alone, as TRE's case does", () {
    write("i/f", utf8.encode("K\nK\n"));

    expect(grep(["-rni", "k", "i"]), (code: 0, output: "i/f:2:K\n"));
  });

  test("-l, -L, -q and no match", () {
    write("re/f", utf8.encode("b\n"));
    write("ctx/f", utf8.encode("x\n"));

    expect(grep(["-rl", "b", "re", "ctx"]), (code: 0, output: "re/f\n"));
    expect(grep(["-rL", "b", "re", "ctx"]), (code: 0, output: "ctx/f\n"));
    expect(grep(["-rqc", "x", "re", "ctx"]), (code: 0, output: "re/f:0\n"));
    expect(grep(["-rn", "nothing", "re"]), (code: 1, output: ""));
  });

  test("whatever might be answered otherwise is the guest's", () {
    write("d/f", utf8.encode("café\nabc\n"));
    Link(
      p.join(workspace, "out", "passwd"),
    ).createSync("/etc/passwd", recursive: true);

    for (final args in [
      ["-n", "abc", "d/f"], // not recursive
      ["-rn", "abc"], // stdin
      ["-ro", "abc", "d"],
      ["-rn", "-f", "pats", "d"],
      ["-rn", r"\(a\)\1", "d"], // a back reference
      ["-rn", "[[:alpha:]]", "d"], // musl's tables past ASCII
      ["-rn", "abc", "out"], // a link off the mounts
      ["-rn", "abc", "/etc"],
      ["-rn", "--include=*.dart", "abc", "d"],
    ]) {
      expect(GrepJob.search("/root", args, mounts), isNull, reason: "$args");
    }
  });
}
