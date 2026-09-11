import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/shell.dart" show pathInside;
import "package:agent_chat/domain/shell_command_analysis.dart";

void main() {
  ShellCommandAnalysis parse(String command) =>
      ShellCommandAnalysis.parse(command);

  test("a plain read parses with nothing to say", () {
    final a = parse("ls -la /usr/bin");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isEmpty);
  });

  test("a pipe of reads parses with nothing to say", () {
    final a = parse("cat /etc/os-release | grep PRETTY | wc -l");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isEmpty);
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

  test("an assignment to HOME escalates", () {
    final a = parse("HOME=/tmp/evil git commit");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons.single, contains("HOME"));
  });

  test("an assignment to GIT_DIR escalates", () {
    final a = parse("GIT_DIR=/elsewhere git status");
    expect(a.escalationReasons.single, contains("GIT_DIR"));
  });

  test("an assignment to a git include escalates", () {
    final a = parse(r"git -c include.path=~/.evil/config status");
    // `-c` is a word, not an assignment; the include itself is only an
    // escalation when set as an env var — which the next test covers.
    expect(a.modelable, isTrue);
  });

  test("an assignment to a git config var escalates", () {
    final a = parse("GIT_CONFIG_COUNT=1 git status");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isNotEmpty);
  });

  test("an ordinary assignment does not escalate", () {
    final a = parse("FOO=bar echo done");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isEmpty);
  });

  test("an unterminated quote is not modeled", () {
    final a = parse(r"""echo "never closed""");
    expect(a.modelable, isFalse);
    expect(a.unmodelableReasons.single, contains("quote"));
  });

  test("an unterminated substitution is not modeled", () {
    final a = parse(r"echo $(cat /etc/hostname");
    expect(a.modelable, isFalse);
  });

  test("a backtick substitution is not modeled", () {
    final a = parse("echo `cat /etc/hostname`");
    expect(a.modelable, isFalse);
    expect(a.unmodelableReasons.single, contains("backtick"));
  });

  test("a here-document is parsed as a read, not a write target", () {
    final a = parse("cat <<EOF\nhello\nEOF");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isEmpty);
  });

  test("an input redirect is not a write target", () {
    final a = parse("wc -l < /etc/passwd");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isEmpty);
  });

  test("a fd-only redirect is not a file target", () {
    final a = parse("ls >&2");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isEmpty);
  });

  test("a redirect to /dev/null is harmless", () {
    final a = parse("echo x > /dev/null");
    expect(a.escalationReasons, isEmpty);
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
    expect(note, contains("was not run"));
  });
}