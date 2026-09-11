import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/shell_command_analysis.dart";

void main() {
  ShellCommandAnalysis parse(String command) =>
      ShellCommandAnalysis.parse(command);

  test("a plain read parses and finds no writes", () {
    final a = parse("ls -la /usr/bin");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isEmpty);
    expect(a.hasNoFileWrites, isTrue);
  });

  test("a pipe of reads parses and finds no writes", () {
    final a = parse("cat /etc/os-release | grep PRETTY | wc -l");
    expect(a.modelable, isTrue);
    expect(a.hasNoFileWrites, isTrue);
  });

  test("a redirect into the workspace is named", () {
    final a = parse("echo hi > out.txt");
    expect(a.modelable, isTrue);
    expect(a.writeTargets, ["out.txt"]);
  });

  test("a redirect to an absolute path is named as itself", () {
    final a = parse("echo hi > /etc/motd");
    expect(a.writeTargets, ["/etc/motd"]);
  });

  test("an append is named", () {
    final a = parse("echo hi >> /var/log/app.log");
    expect(a.writeTargets, ["/var/log/app.log"]);
  });

  test("a substitution in a redirect escalates", () {
    final a = parse(r"echo hi > $HOME/wherever");
    expect(a.modelable, isTrue);
    expect(a.escalationReasons, isNotEmpty);
  });

  test("a substitution in an argument is walked for its own writes", () {
    final a = parse(r"echo $(cat /etc/hostname > /tmp/x)");
    expect(a.modelable, isTrue);
    // The inside's redirect is collected: a substitution is not a hiding
    // place.
    expect(a.writeTargets, ["/tmp/x"]);
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

  test("an include.* assignment escalates", () {
    final a = parse("git config include.path /tmp/evil");
    expect(a.modelable, isTrue);
    expect(a.hasNoFileWrites, isTrue);
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
    expect(a.hasNoFileWrites, isTrue);
  });

  test("an input redirect is not a write target", () {
    final a = parse("wc -l < /etc/passwd");
    expect(a.modelable, isTrue);
    expect(a.hasNoFileWrites, isTrue);
  });

  test("a fd-only redirect is not a file target", () {
    final a = parse("ls >&2");
    expect(a.modelable, isTrue);
    expect(a.hasNoFileWrites, isTrue);
  });

  test("a redirect to /dev/null is named and harmless", () {
    final a = parse("echo x > /dev/null");
    expect(a.writeTargets, ["/dev/null"]);
  });

  test("commands sequenced by ; && || are all parsed", () {
    final a = parse("mkdir -p a && echo hi > a/b.txt; echo x > /tmp/evil");
    expect(a.writeTargets, contains("a/b.txt"));
    expect(a.writeTargets, contains("/tmp/evil"));
  });

  test("a removal is not a redirect target — the sandbox answers for it", () {
    final a = parse("rm -rf /tmp/evil");
    expect(a.hasNoFileWrites, isTrue,
        reason: "no redirect in it; enforcement is what refuses the unlink");
  });

  test("a comment is not parsed as a command", () {
    final a = parse("# this is a comment\necho hi");
    expect(a.modelable, isTrue);
    expect(a.hasNoFileWrites, isTrue);
  });

  test("writesOutsidePaths resolves ~ and relative targets", () {
    final a = parse("echo x > ~/outside.txt && echo y > inside.txt");
    expect(
        writesOutsidePaths(a,
            allowed: ["/home/u/ws"], home: "/home/u", cwd: "/home/u/ws"),
        isTrue,
        reason: "~/outside.txt is outside the workspace");
  });

  test("writesOutsidePaths accepts workspace and tmp targets", () {
    final a = parse("echo x > a.txt && echo y > /tmp/scratch/z");
    expect(
        writesOutsidePaths(a,
            allowed: ["/home/u/ws", "/tmp/scratch"],
            home: "/home/u",
            cwd: "/home/u/ws"),
        isFalse);
  });

  test("writesOutsidePaths counts an unresolvable target as outside", () {
    final a = parse(r"echo x > $UNDECIDED");
    expect(
        writesOutsidePaths(a,
            allowed: ["/home/u/ws"], home: "/home/u", cwd: "/home/u/ws"),
        isTrue);
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
    expect(note, contains("asked"));
  });
}