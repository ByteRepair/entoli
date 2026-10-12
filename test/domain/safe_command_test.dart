import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/safe_command.dart";

void main() {
  group("non-modifying", () {
    test("a known read tool with any flags", () {
      for (final segment in [
        "ls -la",
        "cat /etc/hostname",
        "grep -rn needle .",
        "git status --short",
        "git log --oneline -5",
        "git branch",
        "git remote -v",
        "git worktree list",
        "git rev-parse HEAD",
      ]) {
        expect(
          profileSegment(segment).reach,
          SegmentReach.nonModifying,
          reason: segment,
        );
      }
    });

    test("the write and exec flags guard their programs", () {
      for (final segment in [
        "sort -o /etc/hosts names.txt",
        "sort --output=/etc/hosts names.txt",
        "find . -name '*.tmp' -delete",
        "find . -exec rm {} +",
        "file -C magic",
        "git branch -D side-branch",
        "git tag -d v1",
        "git -c core.fsmonitor=x status",
        "git worktree remove ../other",
      ]) {
        expect(
          profileSegment(segment).reach,
          SegmentReach.other,
          reason: segment,
        );
      }
    });

    test("a redirect to a file is a write this layer sees", () {
      expect(profileSegment("ls > /etc/hosts").reach, SegmentReach.other);
      expect(
        profileSegment("grep -rn x . > out.txt").reach,
        SegmentReach.other,
      );
      // Glued and spaced spell the same.
      expect(profileSegment("ls >/etc/hosts").reach, SegmentReach.other);
    });

    test("the throwaway and descriptor targets are no writes", () {
      for (final segment in [
        "ls > /dev/null",
        "git status 2>&1",
        "cat x >&2",
        "du . 2>/dev/null",
      ]) {
        expect(
          profileSegment(segment).reach,
          SegmentReach.nonModifying,
          reason: segment,
        );
      }
    });

    test("anything the words cannot name stands down", () {
      for (final segment in [
        r'echo "$HOME"',
        r"cat $(date).txt",
        r"cd $(pwd) && ls",
      ]) {
        expect(profileSegment(segment).modelable, isFalse, reason: segment);
      }
    });
  });

  group("the fetch family", () {
    test("a plain curl is a network segment with a host", () {
      final profile = profileSegment("curl https://example.com/data.json");
      expect(profile.reach, SegmentReach.network);
      expect(profile.url, "https://example.com/data.json");
      expect(profile.writesDisk, isFalse);
    });

    test("curl's disk flags do not change the reach, only the note", () {
      final profile = profileSegment("curl -o out.bin https://example.com/a");
      expect(profile.reach, SegmentReach.network);
      expect(profile.writesDisk, isTrue);
    });

    test("wget writes by default, stdout forms read", () {
      expect(
        profileSegment("wget https://example.com/a.bin").writesDisk,
        isTrue,
      );
      expect(
        profileSegment("wget -q -O - https://example.com/a.bin").writesDisk,
        isFalse,
      );
      // A spelling the classifier does not read as stdout is still a
      // network segment — the sandbox is what bounds wherever the file
      // lands.
      expect(
        profileSegment("wget -qO- https://example.com/a.bin").reach,
        SegmentReach.network,
      );
      expect(
        profileSegment("wget -qO- https://example.com/a.bin").writesDisk,
        isTrue,
      );
    });

    test("a fetcher with no nameable URL is not network", () {
      expect(profileSegment("curl --help").reach, SegmentReach.other);
    });
  });

  group("package managers stay mutations", () {
    test("npm and pip are not reads and not network", () {
      for (final segment in [
        "npm install left-pad",
        "pip install requests",
        "curl -o x && npm install",
      ]) {
        final profile = profileSegment(segment);
        expect(profile.reach, SegmentReach.other, reason: segment);
      }
    });
  });
}
