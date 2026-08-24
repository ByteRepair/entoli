# Releasing

Publishing a release starts two workflows that share nothing but the event:
`release.yml` attaches the binaries, and `pages.yml` deploys the web app from
the same tag. Either can fail without the other, and only the first checks the
tag against pubspec — a version disagreement stops the binaries and deploys the
site anyway.

Four files are attached, each with a provenance attestation beside it: a signed
`entoli-<version>-<abi>.apk` for each of `armeabi-v7a`, `arm64-v8a` and
`x86_64`, and a `entoli-<version>-x86_64.AppImage`. There is no Play channel
and so no App Bundle: the file on the release is the file that gets installed.
They carry the app's name rather than the package's, since a person is what
downloads them.

**The APK is split per ABI, so a release page offers a choice rather than one
file.** A universal APK carried three copies of every native library and a
phone could use one of them — 125 MB of libraries where an arm64 device wants
94 MB of them, most of that llama.cpp, which is built for arm64 alone. The cost
is that a downloader has to know which one to take, and that **an installer
matching `.apk` finds three**: Obtainium asks which, or takes a regex like
`entoli-.*-arm64-v8a\.apk` to stop asking. There is no universal APK beside
them, deliberately — a fourth file that installs anywhere would be the one
everybody takes, which is the arithmetic above undone.

**Flutter offsets the version code per ABI, and going back to one APK is
therefore a downgrade.** Under `--split-per-abi` its Gradle plugin sets
`versionCode` to `abi * 1000 + <the code below>`, with `armeabi-v7a` 1,
`arm64-v8a` 2 and `x86_64` 4 — so 1.0.0 ships as 11000, 12000 and 14000 rather
than 10000. Within one ABI that stays monotonic in the version, and it is above
what a universal APK of the same version would carry, so the split installs
over an unsplit past. The reverse does not: a universal APK published after
this would report a *lower* code than what is on the phone and Android would
refuse it. Undoing the split means the release that does it also bumps the
version far enough to clear the offset.

**`release.yml` builds none of it.** The builds are `release-build.yml`'s,
which it calls with the tag and which is dispatchable on its own, so whether a
tag builds can be found out without publishing a release to ask. What the two
Linux builds then share is one composite action,
`.github/actions/linux-appimage`; they differ in the mode they pass it and in
what they do with what comes back, which is a bundle and an AppImage either
way. The four signing secrets are named at the call site rather than
`inherit`ed, since only one of the two jobs signs anything.

**Every job that touches Dart starts with `.github/actions/flutter-setup`** —
the SDK pin, the packages and codegen in one step, `linux-appimage`'s own job
included, so no workflow spells a Flutter version out. The generated sources
are not committed, so build_runner runs on every job; the action caches its
asset graph, since the minute it takes is mostly compiling its own entrypoint
rather than producing the four files. It also means the release workflows now
need `tool/prepare.sh` to exist *in the tagged tree*, where before they needed
only `flutter pub get`: rebuilding an older release breaks if the script is
renamed.

**The version is `pubspec.yaml`'s `version:` and nothing else**, resolved in a
job of its own before either build. Every file name is composed there, because
an attestation records its subject by name and the file attested is uploaded
from a different job than the one that built it. That job also names the ABIs,
which is what a split is expected to produce rather than what it chose — the
build fails on an APK it named and did not get, so a Flutter that changes its
default platforms is an error here rather than a release quietly missing a
file. A tag disagreeing with pubspec
fails that job, since a binary reporting a version nobody released cannot be
talked out of it afterwards — and failing there costs seconds rather than two
toolchain installs.

**A release that moves anything under the data directory needs a migration**
named by that same version — see "Migrations" in the root CLAUDE.md. Nothing in
CI checks for one; the check is that the PR moving the files adds it.

**The Android version code is derived from that version rather than stored**,
as `major * 10000 + minor * 100 + patch` — 1.0.0 is 10000, 1.2.3 is 10203, and
Flutter adds the per-ABI offset above on top of it. So
pubspec carries no `+build` suffix: a suffix would be a second number to bump
and so a second number to forget, and forgetting it means a release that will
not install over the one before it. **Minor and patch must stay below 100**, or
1.0.100 and 1.1.0 compute the same code; the workflow fails rather than
shipping the collision. The debug builds are a separate application id
(`.debug`), so the run numbers `debug-build.yml` gives them are never compared
against these. They carry their own name and icon too: see
"The debug build's own".

**Signing material never enters the repository.** Four secrets —
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD` — are decoded into the runner's temp directory, never
into the workspace an artifact is uploaded from.
`android/app/build.gradle.kts` reads the environment first and
`android/key.properties` second, which is deliberate twice over: a stray
properties file in a workspace cannot then change what CI signs with, and a
password survives the environment unaltered, where `java.util.Properties`
reads a backslash in a value as an escape and would corrupt one.

**Where nothing is configured the release build falls back to the debug key,
and that fallback is what the checks are built around.** It keeps
`flutter run --release` working on a machine with no keystore, and Gradle
generates a debug keystore on any runner that lacks one — so a build with the
secrets missing still *succeeds*, and ships an APK that nothing installs over
at the next release. So the run fails before it builds if any of the four
secrets is empty, and asserts on the signer certificate afterwards;
`CN=Android Debug` in `apksigner verify --print-certs` fails it. Gradle applies
the same rule to its own inputs — all four settings or none, since a
half-filled `key.properties` would otherwise reach AGP as a signing config with
null members. The signer's SHA-256 goes in the run summary, because a change in
it is the one thing a user cannot recover from.

**The keystore is the maintainer's and nothing here can regenerate it.**
Android identifies an app by its signing key, so losing it ends the ability to
update Entoli for anyone who already has it. Making one, once:

```sh
keytool -genkey -v -keystore entoli.jks -keyalg RSA -keysize 4096 \
  -validity 10000 -alias entoli
base64 -w0 entoli.jks | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_ALIAS
gh secret set ANDROID_KEY_PASSWORD
```

**The publisher is a job of its own, so the one holding the keystore never also
holds `contents: write`.** It is a matrix over the files the version job named,
one run per binary, because `actions/attest-build-provenance` handed several
subjects mints one bundle naming all of them and a bundle on the release should
be about the file it sits beside. Each run attests its file and attaches the
pair, so a download can be checked against the build that made it:

```sh
gh attestation verify entoli-1.0.0-arm64-v8a.apk --repo Yiannis128/agent-chat
```

The matrix is `fail-fast: false`, since each entry attests and uploads a
different file: one that fails should leave the other three attached, and
`--clobber` is what makes re-running it against them safe.

Keeping the publisher out of the build also means a failed upload re-runs
against the artifacts that were already built and checked rather than a rebuild
that would have to be trusted to match. **A job that never checks out has no git
remote**, which is the trap in that arrangement: `gh release upload` reads the
repository from it and fails with `not a git repository` pointing at the
runner, so the publisher names the repository explicitly.

`workflow_dispatch` takes a tag and rebuilds an existing release for the same
reason: recreating a release to retry a publish changes its timestamp and
notifies every watcher a second time.
