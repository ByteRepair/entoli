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
        "sleep 2",
        "sort -u names.txt",
        "find . -name '*.dart'",
        "file a.png",
        "date +%F",
        "rg -n needle lib",
        "fd -e dart",
        "ps aux",
        "jq .name package.json",
        "test -f pubspec.yaml",
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
        // A file named `2` is what `> 2` writes — fd duplication is the
        // `&`'s to say, and the digits are not descriptors.
        "ls > 2",
        "git branch -D side-branch",
        "git tag -d v1",
        // The guarded flag's = spelling, which the vouch's scan catches and
        // a whole-token scan would miss.
        "git diff --output=/etc/hosts patch.diff",
        // Two arguments is a write target, whatever the subcommand.
        "git symbolic-ref HEAD refs/heads/evil",
        // git spells reflog's delete without a dash.
        "git reflog delete HEAD@{1}",
        // Remote update fetches every remote and writes refs.
        "git remote update",
        "git -c core.fsmonitor=x status",
        "git worktree remove ../other",
        // Writes these read-only tools can still make.
        "echo x >&/tmp/evil",
        "echo x >& /tmp/evil",
        "tree -o /tmp/evil",
        "uniq names.txt /tmp/evil",
        "git show --output=/tmp/evil",
        "git branch --set-upstream-to=origin/x",
        "sort --compress-program=sh names.txt",
        "date -s 2000-01-01",
        "shuf -o /tmp/evil names.txt",
        "rg --pre ./run needle",
        "fd -x rm",
        "dmesg -C",
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
        "ls 2>&-",
        "uniq -c names.txt",
      ]) {
        expect(
          profileSegment(segment).reach,
          SegmentReach.nonModifying,
          reason: segment,
        );
      }
    });

    test("redirects are not arguments", () {
      for (final segment in [
        "git branch 2>/dev/null",
        "git tag > /dev/null",
        "env 2>/dev/null",
        "uniq < names.txt",
        "uniq <<'EOF'\na\nEOF",
      ]) {
        expect(
          profileSegment(segment).reach,
          SegmentReach.nonModifying,
          reason: segment,
        );
      }
      expect(
        profileSegment("curl -s example.com < body.json").url,
        "http://example.com",
      );
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

  group("here-documents", () {
    test("a body is input, not part of the command", () {
      for (final segment in [
        "cat <<'EOF'\n<p>Don't | stop</p> > x\nEOF",
        "grep -n x <<'EOF'\n\$5 `y`\nEOF",
        "cat <<EOF\n<td>\$name</td>\nEOF",
        "ls # > not a redirect",
      ]) {
        expect(
          profileSegment(segment).reach,
          SegmentReach.nonModifying,
          reason: segment,
        );
      }
    });

    test("the command line still decides", () {
      expect(
        profileSegment("cat > f.html <<'EOF'\n<p>x</p>\nEOF").reach,
        SegmentReach.other,
      );
      // An unquoted body runs its substitutions.
      expect(
        profileSegment("cat <<EOF\n\$(rm x)\nEOF").modelable,
        isFalse,
      );
    });
  });

  group("the fetch family", () {
    test("a plain curl is a network segment with a host", () {
      final profile = profileSegment("curl https://example.com/data.json");
      expect(profile.reach, SegmentReach.network);
      expect(profile.url, "https://example.com/data.json");
    });

    test("curl's disk flags change nothing the consult reads", () {
      // Where the fetched bytes land is the sandbox's question, not the
      // network rules'.
      final profile = profileSegment("curl -o out.bin https://example.com/a");
      expect(profile.reach, SegmentReach.network);
      expect(profile.url, "https://example.com/a");
    });

    test("the family's bare-host shape reaches the same rules", () {
      // `curl example.com` is http://example.com to the consult, the
      // scheme the family itself defaults to — the standing answer covers
      // the spelling people actually type.
      for (final segment in [
        "curl example.com/x",
        "wget site.io/data.bin",
        "http api.local:8080",
      ]) {
        expect(
          profileSegment(segment).reach,
          SegmentReach.network,
          reason: segment,
        );
      }
      expect(profileSegment("curl example.com/x").url, "http://example.com/x");
      expect(profileSegment("http api.local:8080").url, "http://api.local:8080");
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
