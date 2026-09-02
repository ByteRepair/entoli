# Releasing

Publishing a release starts two workflows that share nothing but the event:
`release.yml` attaches the binaries and uploads the App Bundle to Google Play,
and `pages.yml` deploys the web app from the same tag. Either can fail without
the other, and only the first checks the tag against pubspec — a version
disagreement stops the binaries and deploys the site anyway.

Five files are attached, each with a provenance attestation beside it: a signed
`entoli-<version>-<abi>.apk` for each of `armeabi-v7a`, `arm64-v8a` and
`x86_64`, a signed `entoli-<version>.aab` for Google Play, and a
`entoli-<version>-x86_64.AppImage`. The APKs and AppImage are the file that
gets installed; the bundle is an input to Play, which resigns it into
per-device APKs of its own. They carry the app's name rather than the
package's, since a person is what downloads them.

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
`inherit`ed, since only the Android jobs sign anything.

**The Android build is three jobs, not one.** The native tools build fetches
the Hexagon SDK and cross-compiles proot and llama.cpp — several gigabytes of
intermediates a single runner did not have room for beside the Gradle build.
`android-tools` builds only, uploads the stripped `dist/` as an artifact, and
the runner is recycled with all its build directories. `android` and `aab`
each download that artifact onto a fresh runner, stage it, and build — split
APKs and an App Bundle respectively, in parallel. `debug-build.yml` splits the
same way, for the same reason. The tools job does not touch Dart.

The setup those three build jobs share — keystore decode (release only), Java
17, Flutter, the tools download and staging — is one composite,
`.github/actions/android-build-setup`, gated by a `release` boolean: debug
passes `false` and skips the keystore; the release jobs pass it the four
secrets. The keystore decode runs first, before the SDK installs, so a missing
one fails in seconds rather than after a toolchain download.

**Every job that touches Dart starts with `.github/actions/flutter-setup`** —
the SDK pin, packages and codegen in one step. The generated sources are not
committed, so build_runner runs on every job; the action caches its asset
graph. The release workflows therefore need `tool/prepare.sh` in the tagged
tree: rebuilding an older release breaks if the script is renamed.

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
into the workspace. `build.gradle.kts` reads the environment first and
`android/key.properties` second, so a stray properties file in a workspace
cannot change what CI signs with, and a password survives the environment
unaltered (where `java.util.Properties` would read a backslash as an escape).
A fifth secret, `PLAY_SERVICE_ACCOUNT_JSON`, is the Play service-account key;
see "Google Play".

**Where nothing is configured the release build falls back to the debug key,
and that fallback is what the checks are built around.** Gradle generates a
debug keystore on any runner that lacks one, so a build with the secrets
missing still succeeds and ships an APK nothing installs over at the next
release. The run fails before it builds if any secret is empty, and asserts on
the signer afterwards: `CN=Android Debug` in `apksigner verify --print-certs`
fails the APK job, and the same string in `keytool -printcert -jarfile` fails
the AAB job (a bundle is a signed jar, so `apksigner` does not apply). The
signer's SHA-256 goes in the run summary, because a change in it is the one
thing a user cannot recover from.

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
different file: one that fails should leave the other four attached, and
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
file on the GitHub release is installed as it is, and the file sent to Play is
an input to something Google builds. `release.yml` calls it after the build, in
parallel with the publish matrix that attaches binaries to the GitHub release.

**Play App Signing uses the project's own keystore rather than a
Google-generated key, and that is what keeps the two channels interchangeable.**
Android identifies an app by its signature, so had Google generated a key, a
Play-delivered update would carry a different signature than every APK released
so far and would refuse to install over one — an Obtainium user moving to Play
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
