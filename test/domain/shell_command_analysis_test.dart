import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/shell.dart" show pathInside;
import "package:agent_chat/domain/shell_command_analysis.dart";

void main() {
  ShellCommandAnalysis parse(String command) =>
      ShellCommandAnalysis.parse(command);

  test("a plain read parses with nothing to say", () {
    for (final command in [
      "ls -la /usr/bin",
      "cat /etc/os-release | grep PRETTY | wc -l",
    ]) {
      final a = parse(command);
      expect(a.modelable, isTrue);
      expect(a.escalationReasons, isEmpty);
    }
  });

  test("a redirect into the workspace needs nothing said", () {
    final a = parse("echo hi > out.txt");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isEmpty);
  });

  test("a substitution in a redirect escalates", () {
    final a = parse(r"echo hi > $HOME/wherever");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isNotEmpty);
  });

  test("a substitution in an argument is walked for its own writes", () {
    final a = parse(r"echo $(cat /etc/hostname > /tmp/x)");
    expect(a.modelable, isTrue);
    // The inside's redirect is walked: a substitution is not a hiding
    // place — but a plain path inside it is still not, by itself, an
    // escalation; the sandbox answers for where it lands.
    expect(a.escalationReasons, isEmpty);
  });

  test(
    "assignments to where writes land or how git reads its config escalate",
    () {
      final home = parse("HOME=/tmp/evil git commit");
      expect(home.modelable, isTrue);
      expect(home.escalationReasons.single, contains("HOME"));

      final gitDir = parse("GIT_DIR=/elsewhere git status");
      expect(gitDir.escalationReasons.single, contains("GIT_DIR"));

      final gitVar = parse("GIT_CONFIG_COUNT=1 git status");
      expect(gitVar.modelable, isTrue);
      expect(gitVar.escalationReasons, isNotEmpty);
    },
  );

  test("assignments that are not sensitive do not escalate", () {
    // `-c` is a word, not an assignment; the include is an escalation only
    // when set as an env var, which the sensitive test above covers.
    final include = parse(r"git -c include.path=~/.evil/config status");
    expect(include.modelable, isTrue);

    final ordinary = parse("FOO=bar echo done");
    expect(ordinary.modelable, isTrue);
    expect(ordinary.escalationReasons, isEmpty);
  });

  test("a tokenizer failure is not modeled", () {
    final quoted = parse(r"""echo "never closed""");
    expect(quoted.modelable, isFalse);
    expect(quoted.unmodelableReasons.single, contains("quote"));

    // And neither is a substitution that never closes.
    final substituted = parse(r"echo $(cat /etc/hostname");
    expect(substituted.modelable, isFalse);

    // A backtick is yesterday's substitution: refused by kind.
    final backticked = parse("echo `cat /etc/hostname`");
    expect(backticked.modelable, isFalse);
    expect(backticked.unmodelableReasons.single, contains("backtick"));
  });

  test("redirects that are not write targets are not escalations", () {
    // A here-document is a read, not a write target.
    final here = parse("cat <<EOF\nhello\nEOF");
    expect(here.modelable, isTrue);
    expect(here.escalationReasons, isEmpty);

    // So is an input redirect.
    final input = parse("wc -l < /etc/passwd");
    expect(input.modelable, isTrue);
    expect(input.escalationReasons, isEmpty);

    // A fd-only redirect has no file target at all.
    final fd = parse("ls >&2");
    expect(fd.modelable, isTrue);
    expect(fd.escalationReasons, isEmpty);

    // And /dev/null is harmless.
    final devnull = parse("echo x > /dev/null");
    expect(devnull.escalationReasons, isEmpty);
  });

  test("commands sequenced by ; && || are all parsed", () {
    final a = parse("mkdir -p a && echo hi > a/b.txt; echo x > /tmp/evil");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isEmpty);
  });

  test("a redirect cut off by a separator escalates rather than throwing", () {
    for (final command in ["echo a >| out", "echo a > ; b", "echo a > && b"]) {
      expect(parse(command).escalationReasons, isNotEmpty, reason: command);
    }
  });

  group("here-documents", () {
    test("a quoted body is text, whatever it holds", () {
      const body =
          "<pre>| Back | Front |</pre>\n<p>Don't</p> `x` \$(rm a) "
          "\$HOME > b; # c";
      for (final command in [
        "cat >> f.html <<'EOF'\n$body\nEOF",
        'cat > f <<"EOF"\n$body\nEOF',
        "cat > f <<\\EOF\n$body\nEOF",
      ]) {
        final a = parse(command);
        expect(a.modelable, isTrue, reason: command);
        expect(a.escalationReasons, isEmpty, reason: command);
      }
    });

    test("an unquoted body's substitutions are walked", () {
      final a = parse("cat > f <<EOF\n<p>\$(echo x > \$HOME/y)</p>\nEOF");
      expect(a.escalationReasons, isNotEmpty);
      expect(
        parse("cat > f <<EOF\n<p>\$name | it's</p>\nEOF").escalationReasons,
        isEmpty,
      );
      expect(parse("cat > f <<EOF\n`id`\nEOF").modelable, isFalse);
    });

    test("the command after the body is parsed on its own", () {
      final a = parse("cat > f <<'EOF'\na | b\nEOF\nHOME=/tmp ls");
      expect(a.escalationReasons, isNotEmpty);
      expect(a.modelableSegments, [
        "cat > f <<'EOF'\na | b\nEOF",
        "HOME=/tmp ls",
      ]);
    });

    test("<<- strips tabs, and two bodies are read in order", () {
      expect(parse("cat <<-EOF\n\tx | y\n\tEOF").modelable, isTrue);
      final a = parse("cat <<'A' - <<'B'\n'\nA\n'\nB\necho done");
      expect(a.modelable, isTrue);
      expect(a.escalationReasons, isEmpty);
    });

    test("a body goes back on the segment whose << it feeds", () {
      expect(parse("cat <<'EOF' | head\nx | y\nEOF").modelableSegments, [
        "cat <<'EOF'\nx | y\nEOF",
        "head",
      ]);
      // The pipe carries on past the body, so what follows is its own
      // segment and a rule on it still sees it.
      expect(parse("cat <<'EOF' |\nx\nEOF\nrm -rf /tmp/a").modelableSegments, [
        "cat <<'EOF'\nx\nEOF",
        "rm -rf /tmp/a",
      ]);
    });

    test("a body that never closes is not modeled", () {
      expect(parse("cat > f <<'EOF'\nbody").modelable, isFalse);
      expect(parse("cat > f <<").modelable, isFalse);
    });
  });

  test("segments are cut where the parse cuts commands", () {
    expect(parse(r"echo $a; ls").modelableSegments, [r"echo $a", "ls"]);
    expect(parse("ls &> f; cmd 2>&1 | head").modelableSegments, [
      "ls &> f",
      "cmd 2>&1",
      "head",
    ]);
    expect(parse("a &&\nb").modelableSegments, ["a", "b"]);
  });

  test("a duplication's target is read: a descriptor, or a file it writes", () {
    expect(parse(r"echo x >&$X").escalationReasons, isNotEmpty);
    expect(parse("cmd 2>&1 | head").escalationReasons, isEmpty);
  });

  test("a newline ends a command", () {
    expect(parse("echo a\nHOME=/tmp ls").escalationReasons, isNotEmpty);
    expect(isFileToolWork("git log |\nhead -5"), isFalse);
  });

  test("a removal is not a redirect target — the sandbox answers for it", () {
    final a = parse("rm -rf /tmp/evil");
    expect(
      a.escalationReasons,
      isEmpty,
      reason: "no redirect in it; enforcement is what refuses the unlink",
    );
  });

  test("a substitution is held to the top level's rules, nested too", () {
    for (final command in [
      r"echo $(echo x > $HOME/y)",
      r"echo $(echo $(HOME=/tmp/evil ls))",
    ]) {
      expect(parse(command).escalationReasons, isNotEmpty, reason: command);
    }
  });

  test("a comment is not parsed as a command", () {
    final a = parse("# this is a comment\necho hi");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isEmpty);
  });

  test("pathInside compares by components", () {
    expect(pathInside("/ws/x/y", "/ws"), isTrue);
    expect(pathInside("/wextra", "/ws"), isFalse);
    expect(pathInside("/ws", "/ws"), isTrue);
  });

  test("Windows commands are escalated, not parsed", () {
    final a = ShellCommandAnalysis.parse("dir > C:\\evil.txt", isWindows: true);
    expect(a.modelable, isFalse);
    expect(a.escalationNote, isNotNull);
  });

  test("the escalation note is worded for the model", () {
    final a = parse("HOME=/tmp git push");
    final note = a.escalationNote;
    expect(note, isNotNull);
    expect(note, contains("HOME"));
    expect(
      note,
      isNot(contains("asked")),
      reason: "nothing asked anyone; the wording says what happened",
    );
    expect(note, contains("Not run"));
  });

  test("the note names the segments where the parse saw them", () {
    final note = parse("cd /x && HOME=/tmp/evil git push").escalationNote!;
    expect(note, contains("cd /x"));
    expect(note, contains("separate bash calls"));
  });

  test("a tokenizer failure names nothing but the reason", () {
    final note = parse(r'echo "unclosed').escalationNote!;
    expect(note, isNot(contains("- cd")), reason: "nothing reliable to name");
    expect(note, contains("split"));
  });
  group("isFileToolWork", () {
    test("names a file read or written through the shell", () {
      for (final command in [
        "cat notes.txt",
        "head -n 20 src/main.c",
        "cd repo && sed -n '80,130p' setup.py",
        "sed -i 's/a/b/' x.txt",
        "echo hi > out.txt",
        "cat > f.txt <<'EOF'\nbody\nEOF",
      ]) {
        expect(isFileToolWork(command), isTrue, reason: command);
      }
    });

    test("leaves pipes, programs and discarded output alone", () {
      for (final command in [
        "git log | head -5",
        "ls -la | sed 's/x/y/'",
        "flutter test",
        "echo done 2>/dev/null",
        "grep -rn foo lib",
      ]) {
        expect(isFileToolWork(command), isFalse, reason: command);
      }
    });
  });
}
