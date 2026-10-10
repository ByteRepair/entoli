# Releasing

Publishing a release starts two workflows that share nothing but the event:
`release.yml` attaches the binaries and uploads the App Bundle to Google Play,
and `pages.yml` deploys the web app from the same tag. Either can fail without
the other, and only the first checks the tag against pubspec — a version
disagreement stops the binaries and deploys the site anyway.

Two files are attached, each with a provenance attestation beside it: a signed
`entoli.aab` for Google Play and a `entoli-x86_64.AppImage`. The bundle is an
input to Play, which resigns it into per-device APKs of its own. A third,
`entoli-universal.dmg`, joins them unsigned: no Developer ID identity and
notarytool profile exist until enrollment, the ad-hoc build running through
Finder's right-click Open, and `release-build.yml`'s macos job grows the
signing at the same time — see "The DMG" in `macos/AGENTS.md`. They carry the
app's name rather than the package's, since a person is what downloads them,
and no version, since the tag releases; the same names serve every release.

**There is no release APK.** Play is the Android channel a release serves;
Google builds the per-device APKs from the bundle itself, and anyone who wants
a hand install builds one with `flutter build apk` — locally, or through
`debug-build.yml`'s dispatch, which is where its debug application id and run
numbers are handled. A release page offering a choice of APKs cost more than
it returned: three flavours was one decision for a downloader to get right.

**`release.yml` builds none of it.** The builds are `release-build.yml`'s,
which it calls with the tag and which is dispatchable on its own, so whether a
tag builds can be found out without publishing a release to ask. What the two
Linux builds share is one composite action, `.github/actions/linux-appimage`;
they differ in the mode they pass it and in what they do with what comes back,
which is a bundle and an AppImage either way. The four signing secrets are
named at the call site rather than `inherit`ed, since only the Android job
signs anything.

**The Android build is two jobs, not one.** The native tools build fetches the
660 MiB Hexagon SDK and cross-compiles proot and llama.cpp — several gigabytes
of intermediates a single runner did not have room for beside the Gradle
build. `android-tools` builds only, uploads the stripped `dist/` as an
artifact, and the runner is recycled with all its build directories. `aab`
downloads that artifact onto a fresh runner with the full disk free for
Gradle, and pays its own Gradle setup — wrapper download, plugin and
dependency resolution, the SDK components Gradle fetches — inline. A priming
job and a warm Gradle cache once stood between it and that work; they existed
to be shared between two build jobs, and with one consumer left they paid the
same configure twice and moved a multi-gigabyte entry nobody else read. The
tools job does not touch Dart.

**The aab job deletes the image's preinstalled NDKs, but for its own.** The
runner image ships NDKs under `$ANDROID_HOME/ndk` that `ndkVersion` does not
name — the build's pin comes from Flutter (`flutter.ndkVersion`, the
FlutterExtension.kt constant of the SDK flutter-setup installs), not from
the image. On ubuntu-24.04, where the v4.6.0 aab job died, three of them
(~7 GB) sat beside the fourth Gradle went on to install itself, and the
build failed inside `signReleaseBundle` with bundletool's "Location not
within channel boundaries" — a disk-full error wearing a password — with 82
MB left. The step deletes every NDK but the pinned one, which is why 26.04 —
where ubuntu-latest lands in November 2026 and which preinstalls exactly
Flutter 3.44's pin — keeps working with nothing to install. The number is
stated in `android-build-setup` rather than read from Flutter, and a stale
one never breaks the build: the worst it does is leave an NDK behind.

**The Linux build is two jobs, not one, for the same reason.** `llama-linux`
builds the desktop model server (`.github/actions/linux-llama`, over
`tool/linux/build-llama.sh`) and uploads the stage as an artifact; `linux`
downloads it before `flutter build linux`, so the bundle either carries the
server whole or not at all — the artifact check between the download and the
build is what says which. The cache lives on the llama job, whose only other
content is two apt packages on a miss, so a cache miss costs the build alone
rather than a Flutter setup too; the app job carries no llama cache at all,
and its composite (`linux-appimage`) installs nothing for the server. One
trap this closes: the cache's post-save never ran where the job failed
mid-composite — the first run of the llama step was thrown away whole, and
every retry rebuilt it — so a build worth caching is worth a job that does
nothing besides it.

**`LLAMA_OPENSSL` is pinned OFF, in both builds.** The option defaults ON,
and where the host has libssl3's dev files — the ubuntu runner, most
desktops — cpp-httplib links `libssl.so.3` into the server, which the
staging check refuses: the bundle ships what the app owns plus the
libc-family names, and a distro's SSL is neither. The Android cross build
gets there the same way; the pin replaces an accident (no OpenSSL for
`find_package` to find under the NDK) with a statement, so a future NDK
that ships OpenSSL fails at staging rather than on a phone. The app does
its own downloading; the server is local inference.

The setup the build jobs share — keystore decode (release only), Java 17,
Flutter, the tools download and staging — is one composite,
`.github/actions/android-build-setup`, gated by a `release` boolean: debug
passes `false` and skips the keystore; the release job passes it the four
secrets. It also rewrites `android/gradle.properties`' `-Xmx8G`
/-`MaxMetaspaceSize=4G` down to 4G/1G on every runner: those are workstation
figures, and a JVM that grows past what a hosted runner has left does not
fail the build — it loses the runner mid-build, which is how the v2.2.0 App
Bundle job died at 58 minutes with no logs. The keystore decode runs first,
before the SDK installs, so a missing one fails in seconds rather than after
a toolchain download.

**Every job that touches Dart starts with `.github/actions/flutter-setup`** —
the SDK pin, packages and codegen in one step. The generated sources are not
committed, so build_runner runs on every job; the action caches its asset
graph. The release workflows therefore need `tool/prepare.sh` in the tagged
tree: rebuilding an older release breaks if the script is renamed.

**The version is `pubspec.yaml`'s `version:` and nothing else**, resolved in a
job of its own before either build. The file names are composed in that job
too, and none of them carries the version — one name is one file on every
release, the tag being what says the version. Composing them in that job still
matters, because an attestation records its subject by name and the file
attested is uploaded from a different job than the one that built it. A tag
disagreeing with pubspec fails there, since a binary reporting a version nobody
released cannot be talked out of it afterwards — and failing there costs
seconds rather than two toolchain installs.

**A release that moves anything under the data directory needs a migration**
named by that same version — see "Migrations" in the root AGENTS.md. Nothing in
CI checks for one; the check is that the PR moving the files adds it.

**The Android version code is derived from that version rather than stored**,
as `major * 10000 + minor * 100 + patch` — 1.0.0 is 10000, 1.2.3 is 10203; the
AppImage gets the same code. So pubspec carries no `+build` suffix: a suffix
would be a second number to bump and so a second number to forget, and
forgetting it means a release that will not install over the one before it.
**Minor and patch must stay below 100**, or 1.0.100 and 1.1.0 compute the same
code; the workflow fails rather than shipping the collision. The debug builds
are a separate application id (`.debug`), so the run numbers `debug-build.yml`
gives them are never compared against these. They carry their own name and
icon too: see "The debug build's own".

**Signing material never enters the repository.** Four secrets —
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD` — are decoded into the runner's temp directory, never
into the workspace. `build.gradle.kts` reads the environment first and
`android/key.properties` second, so a stray properties file in a workspace
cannot change what CI signs with, and a password survives the environment
unaltered (where `java.util.Properties` would read a backslash as an escape).
A fifth secret, `PLAY_SERVICE_ACCOUNT_JSON`, is the Play service-account key;
see "Google Play".

**Where nothing is configured the release build falls back to the debug key,
and that fallback is what the checks are built around.** Gradle generates a
debug keystore on any runner that lacks one, so a build with the secrets
missing still succeeds and ships a bundle nothing installs over at the next
release. The run fails before it builds if any secret is empty, and asserts on
the signer afterwards: the `CN=Android Debug` string fails the bundle in
`keytool -printcert -jarfile`, the bundle being a signed jar. The signer's
SHA-256 goes in the run summary, because a change in it is the one thing a
user cannot recover from.

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
gh attestation verify entoli-x86_64.AppImage --repo Yiannis128/agent-chat
```

The matrix is `fail-fast: false`, since each entry attests and uploads a
different file: one that fails should leave the other attached, and
`--clobber` is what makes re-running it against them safe. The App Bundle
attests the `.aab` that Play receives, so the same check covers both channels.

Keeping the publisher out of the build also means a failed upload re-runs
against the artifacts that were already built and checked rather than a rebuild
that would have to be trusted to match. **A job that never checks out has no git
remote**, which is the trap in that arrangement: `gh release upload` reads the
repository from it and fails with `not a git repository` pointing at the
runner, so the publisher names the repository explicitly.

`workflow_dispatch` takes a tag and rebuilds an existing release for the same
reason: recreating a release to retry a publish changes its timestamp and
notifies every watcher a second time.

## Google Play

`publish-play.yml` uploads the App Bundle to Google Play, which resigns it into
per-device APKs of its own — the whole difference between the two channels: the
AppImage is installed as it is, and the file sent to Play is an input to
something Google builds. Play is the only Android channel a release serves;
`release.yml` calls it after the build, in parallel
with the publish matrix that attaches binaries to the GitHub release.

**Play App Signing uses the project's own keystore rather than a
Google-generated key, and that is what keeps the two channels interchangeable.**
Android identifies an app by its signature, so had Google generated a key, a
Play-delivered update would carry a different signature than every APK released
so far and would refuse to install over one — a user moving to Play
would have to uninstall and lose their chats, settings and workspace first, and
so would anyone going the other way. Uploading the existing key instead means
both channels deliver the same signature and a user can switch either way as an
ordinary update. **This was a one-time, irreversible choice made when the app
was created**; there is no changing it afterwards.

**The first upload cannot come from here.** The Play Developer API refuses to
create an app's first release — a bundle has to go up through the Console by
hand once, after which this workflow owns every release. This is not something
the workflow can detect and explain; it surfaces as an API error on a run that
otherwise looks correct.

Four things have to exist before the job works at all, and none of them lives
in this repository:

- A **service account** in a Google Cloud project, with a JSON key. Google no
  longer wants the developer account linked to that project as a separate step
  — the link is made by the permission grant below. If an upload comes back
  saying the API is not enabled, enable **Google Play Android Developer API**
  on that project.
- That service account invited under the Play Console's **Users and
  permissions**, granted **Release apps to testing tracks** and, once
  production unlocks, **Release to production, exclude devices, and use Play
  App Signing**. Both are **app-level**, so they are granted on Entoli rather
  than across the account. It is created with no permissions at all; the
  Console is where they are given. **Manage store presence** is not needed —
  release notes ride with the release.
- The JSON key stored as the repository secret **`PLAY_SERVICE_ACCOUNT_JSON`**,
  beside the four `ANDROID_*` ones. The job fails on an empty secret before it
  downloads anything, for the same reason the keystore check does.

**That key is the one credential here that is cheap to lose.** Unlike the
upload keystore, it can be deleted in the Cloud console and a new one issued in
a minute, so rotate it freely and on any doubt.

**Release notes are the GitHub release body, or nothing.** Play caps them at
500 characters and rejects the upload rather than truncating, so a body over
the cap is dropped with a warning instead of cut: a listing ending mid-sentence
is worse than one written in the Console, where the maintainer already is. Only
`whatsnew-en-US` is written, since the release body is English; a Greek listing
keeps whatever the Console holds rather than being handed English text under a
Greek locale.

**What Play requires that no workflow can supply.** A rejected upload is
usually none of the above. The data safety form, the content rating
questionnaire, a reachable privacy policy, the target API level Play currently
demands and the declarations tied to specific permissions are all Console
state, they expire or tighten on Google's schedule rather than on a release,
and any of them will fail an upload that was built perfectly.

### Production is locked, so releases go to Alpha

A personal developer account opened after 13 November 2023 cannot publish to
production until it has run a **closed** test with at least twelve testers
opted in for fourteen *continuous* days, after which production access is
applied for and reviewed in seven days or less. Internal and open testing do
not count, and a tester who opts out and back in resets to zero — the clock is
per tester, counted backwards from the day you apply, so everyone has to be in
on the same day.

`publish-play.yml` therefore names `alpha`, the closed track Play creates with
the app, and **`TRACK` and `STATUS` move together**. A draft reaches nobody,
which on a closed track means no tester ever installs anything and the fourteen
days never begin, so the caution that leaves a production release for a person
to send is wrong here — that caution is about a release that cannot be recalled
from strangers' phones, and twelve people who opted in deliberately are not
that. Both go back to `production` and `${{ inputs.publish && 'completed' ||
'draft' }}` in one edit when Play unlocks it, and `publish` is inert until
they do.

### The application id cannot be a job output

`release-build.yml`'s AAB job parses it out of Gradle and writes
`dist/package.txt` into the `aab` artifact, and `publish-play.yml` reads it
back from there. That looks like the long way round, and it is there because
**GitHub drops a job output whose value contains a registered secret's value**
— the signing key alias is a substring of `io.byterepair.entoli`, so the output
would arrive at the publisher empty and Play would reject an upload naming no
package, which reads as a Play misconfiguration rather than as a value lost in
transit. The only sign is one annotation on the build job, `Skip output
'package' since it may contain secret`.

The check applies to outputs crossing a job boundary, not to files, and not to
a step output inside a job where the secret is not in scope. So the id survives
the artifact and survives being read back in the publisher, which references
none of the `ANDROID_*` secrets. Parsing stays in the job that checks out and
builds, so the id uploaded under still cannot drift from the id built with.

Nothing leaked, and the masking was working: the alias is simply a poor secret,
being a substring of an application id that is public in Gradle, in the Play
URL and in every release.