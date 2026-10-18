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

  test("assignments to where writes land or how git reads its config escalate", () {
    final home = parse("HOME=/tmp/evil git commit");
    expect(home.modelable, isTrue);
    expect(home.escalationReasons.single, contains("HOME"));

    final gitDir = parse("GIT_DIR=/elsewhere git status");
    expect(gitDir.escalationReasons.single, contains("GIT_DIR"));

    final gitVar = parse("GIT_CONFIG_COUNT=1 git status");
    expect(gitVar.modelable, isTrue);
    expect(gitVar.escalationReasons, isNotEmpty);
  });

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

  test("a removal is not a redirect target — the sandbox answers for it", () {
    final a = parse("rm -rf /tmp/evil");
    expect(a.escalationReasons, isEmpty,
        reason: "no redirect in it; enforcement is what refuses the unlink");
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
    expect(note, isNot(contains("asked")),
        reason: "nothing asked anyone; the wording says what happened");
    expect(note, contains("Not run"));
  });

  test("the note names the segments where the parse saw them", () {
    final note =
        parse("cd /x && HOME=/tmp/evil git push").escalationNote!;
    expect(note, contains("cd /x"));
    expect(note, contains("separate bash calls"));
  });

  test("a tokenizer failure names nothing but the reason", () {
    final note = parse(r'echo "unclosed').escalationNote!;
    expect(note, isNot(contains("- cd")), reason: "nothing reliable to name");
    expect(note, contains("split"));
  });
}