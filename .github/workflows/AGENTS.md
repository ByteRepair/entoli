# Releasing

A release event starts two workflows that share nothing but the event:
`release.yml` attaches the binaries and uploads the App Bundle to Google
Play, `pages.yml` deploys the web app from the same tag. Either can fail
without the other, and only the first checks the tag against pubspec — a
version disagreement stops the binaries and deploys the site anyway.

Three files are attached, each with a provenance attestation beside it, named
after the app and not the package or the version (a person is what downloads
them, and the tag is where a version lives), so the same names serve every
release:

- `entoli.aab`, signed, for Google Play — an input to Play, which resigns
  it into per-device APKs of its own
- `entoli-x86_64.AppImage`
- `entoli-arm64.dmg`, for Apple silicon, signed with the Developer ID Application
  certificate (`MACOS_CERT_P12` and `MACOS_CERT_PASSWORD`, a base64 `.p12`
  and its password) and notarized with the App Store Connect API key the ipa
  is signed with, the ticket stapled into the image — see "The DMG" in
  `macos/AGENTS.md`

A fourth, `entoli-installer.msi`, attaches the same way: the version job's
`assets` list carries it and the publish matrix uploads every entry alike;
see `windows/AGENTS.md`.

A fifth, `entoli.ipa`, attaches the same way and is also the file that went
up to TestFlight; the store redistributes what Apple resigns, so the
attestation is about the build as uploaded rather than the artifact users
get.

**There is no release APK.** Play is the Android channel a release serves;
Google builds the per-device APKs from the bundle itself, and anyone who
wants a hand install builds one with `flutter build apk`, locally or
through `debug-build.yml`'s dispatch. **`release.yml` builds none of the
assets.** The builds are `release-build.yml`'s, which it calls with the tag
and which is dispatchable on its own, so whether a tag builds can be found
out without publishing a release to ask. The two Linux builds share the
composite `.github/actions/linux-appimage` and differ in the mode they pass
it; the nine signing secrets are named at the call site rather than
`inherit`ed, three jobs signing.

## The jobs

**They are split in two wherever a second toolchain would leave one runner
without the disk or the minutes for the app build.** `android-tools`
fetches the 660 MiB Hexagon SDK and cross-compiles proot and llama.cpp,
uploads the stripped `dist/` as an artifact, and touches no Dart; the `aab`
job downloads it onto a fresh runner with the disk free for Gradle and pays
the Gradle setup — wrapper, plugins, SDK components — inline. So on the
desktop: `llama-linux` builds the model server
(`.github/actions/linux-llama`, over `tool/linux/build-llama.sh`), and
`linux` downloads the stage before `flutter build linux`, so the bundle
carries the server whole or not at all — the check between download and
build is what says which. The caches live on the native jobs, whose only
other content is two apt packages, so a miss costs the native build alone;
the app jobs carry no llama cache.

**The aab job deletes every NDK the image preinstalled but its own.** The
image ships NDKs under `$ANDROID_HOME/ndk` that `ndkVersion` does not name
— the build's pin comes from Flutter, not the image — and three of them
(~7 GB) beside the one Gradle installs left the v4.6.0 build dead inside
`signReleaseBundle` with 82 MB free: bundletool's "Location not within
channel boundaries", a disk-full error wearing a password. On 26.04 the
image's set is exactly Flutter 3.44's pin and there is nothing to delete.
The number is stated in `android-build-setup` rather than read from
Flutter, so a stale pin's worst effect is an NDK left behind.

**`LLAMA_OPENSSL` is pinned OFF, in both builds.** The option defaults ON,
and where libssl3's dev files are present — the ubuntu runner, most
desktops — cpp-httplib links `libssl.so.3` into the server, which the
staging check refuses: the bundle ships what the app owns plus the
libc-family names, and a distro's SSL is neither. The pin makes a statement
of what was once an accident, so a future NDK that ships OpenSSL fails at
staging rather than on a phone.

The setup the Android build jobs share — keystore decode (release only),
Java 17, Flutter, the tools download and staging — is one composite,
`.github/actions/android-build-setup`, gated by a `release` boolean; debug
passes `false` and skips the keystore. The decode runs before the SDK
installs, so a missing one fails in seconds rather than after a toolchain
download. It also rewrites the workstation JVM figures in
`android/gradle.properties` (`-Xmx8G`, `-XX:MaxMetaspaceSize=4G`) down to
4G/1G: a JVM grown past what a hosted runner has left does not fail the
build, it loses the runner mid-build — the v2.2.0 App Bundle job died at 58
minutes, no logs.

**The ipa job is one runner where Android needed two.** The iSH core is a
minutes-long clang of one static library, not a toolchain with gigabytes of
its own, so `ios` checks the submodule out itself (recursive; `build.sh`'s
own init is the fallback for a bare checkout), brews LLVM and lld for the
i386 vdso, runs `tool/ios/ish/build.sh`, and then the app build. The
xcframework is cached on the submodule gitlink plus the two repo files under
it, so a release whose iSH pin has not moved restores it and skips the brew
and the compile. Signing is Xcode's automatic signing, and no certificate
or profile is stored anywhere: `flutter build ipa --no-codesign` archives
unsigned, then `xcodebuild -exportArchive -allowProvisioningUpdates` signs
the export with the App Store Connect API key, Apple handing back (or
creating) a cloud-managed distribution certificate and an App Store profile.
Unsigned is deliberate: an archive signed on a fresh runner would mint an
Apple Development certificate every run, and the team caps those. It holds
because the Runner target carries no entitlements file; one added later
wants checking that the export still applies it. The export options are
`tool/ios/ExportOptions.plist` — the file an upload from a Mac uses, so the
two cannot drift — with its `destination` switched from `upload` to
`export`, since here the ipa goes to disk and the `testflight` job uploads
it. The key is decoded into runner temp and dies with the runner. Empty signing
secrets fail the job on the first step, before the runner fetches anything —
the decode-before-build rule `android-build-setup` runs on, at its whole
width.

**The TestFlight upload is release.yml's `testflight` job, not the
build's.** Apple's upload-and-processing wall clock belongs beside Play's,
in parallel with the publish matrix: a build whose Apple side is slow still
attaches its five assets. The job downloads the `ipa` artifact and uploads
it with `altool`, skipping with a notice when the API trio is absent and
saying so in the step summary as well as the log when a runner's Xcode has
stopped shipping altool. A bare dispatch of `release-build.yml` therefore
builds and uploads nothing to any store, matching its contract.

**The ipa declares itself exempt from export documentation, and that holds
only while France is out of the app's availability** — the condition is
App Store Connect's setting, not anything in the tree; see "Export
compliance" in `ios/AGENTS.md`. Nothing here can read that setting, so the
`testflight` job says it in the step summary of every upload instead, where
the person cutting the release reads it.

**Every job that touches Dart starts with `.github/actions/flutter-setup`**
— the SDK pin, packages and codegen. The generated sources are not
committed, so build_runner runs on every job; the action caches the asset
graph. The release workflows therefore need `tool/prepare.sh` in the
tagged tree: rebuilding an older release breaks if the script is renamed.

## The version

**The version is `pubspec.yaml`'s `version:` and nothing else**, resolved
in a job of its own before either build: a tag disagreeing with pubspec
would ship a binary reporting a version nobody released, and failing there
costs seconds rather than two toolchain installs.

The file names are composed in that job — none carries the version, as one
name is one file on every release, the tag saying the version — and are
published as outputs, because the publisher names the file it uploads from
a different job than the one that built it, and an attestation records its
subject by name.

**The Android version code is derived from the version rather than
stored**, as `major * 10000 + minor * 100 + patch` (1.0.0 is 10000, 1.2.3
is 10203); the AppImage and the ipa get the same code. Pubspec carries no `+build`
suffix: a second number to bump is a second number to forget, and
forgetting it is a release that will not install over the one before.
**Minor and patch must stay below 100** — 1.0.100 and 1.1.0 would compute
the same code — and the workflow fails rather than shipping the collision.
The debug builds are a separate application id (`.debug`), so the run
numbers `debug-build.yml` gives them are never compared against these.

**A release that moves anything under the data directory needs a
migration** named by that same version — see "Migrations" in the root
AGENTS.md. No CI check; the check is the PR adding one.

## Signing

**Signing material never enters the repository.** Four secrets —
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` — are decoded into the
runner's temp directory, never the workspace. `build.gradle.kts` reads the
environment first and `android/key.properties` second, so a stray
properties file cannot change what CI signs with, and the password survives
the environment unaltered (`java.util.Properties` would read a backslash as
an escape). A fifth secret, `PLAY_SERVICE_ACCOUNT_JSON`, is the Play
service-account key; see "Google Play" below.

**Where nothing is configured the build falls back to the debug key, and
the checks are built around that.** Gradle generates a debug keystore on
any runner lacking one, so missing secrets still succeed and ship a bundle
nothing installs over at the next release. The run fails before it builds
if any secret is empty, and asserts on the signer after —
`keytool -printcert -jarfile`, the bundle being a signed jar, and
`CN=Android Debug` failing it. The signer's SHA-256 goes in the run
summary, a change in it being the one thing a user cannot recover from.

**The keystore is the maintainer's, and nothing here can regenerate it.**
Android identifies an app by its signing key, so losing it ends the ability
to update Entoli for anyone who already has it. Making one, once:

```sh
keytool -genkey -v -keystore entoli.jks -keyalg RSA -keysize 4096 \
  -validity 10000 -alias entoli
base64 -w0 entoli.jks | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_ALIAS
gh secret set ANDROID_KEY_PASSWORD
```

Apple's three are optional where the Android four are required:
`APPLE_API_ISSUER`, `APPLE_API_KEY_ID` and `APPLE_API_KEY_P8` (base64 of
the `.p8`) are one App Store Connect API key, which both signs the export in
`release-build.yml` and uploads in `release.yml`'s `testflight` job. The team
is not a secret: it is the project's `DEVELOPMENT_TEAM` and the `teamID` of
`tool/ios/ExportOptions.plist`, both committed. The same key notarizes the
DMG in the macos job. A caller without them ships every build but the ipa
and the DMG. The key needs the **Admin** role: App Manager uploads but
cannot create the certificate or profile the export asks for. Nothing about
the ipa goes stale yearly — Apple renews the cloud-managed certificate and
regenerates the profile itself — and a leaked key is revoked in App Store
Connect and replaced by a new trio, nothing else changing.

The DMG's certificate is the exception: `MACOS_CERT_P12` (base64 of a
`.p12`) and `MACOS_CERT_PASSWORD` are the Developer ID Application
certificate and its key, a stored file because `flutter build macos` is not
an Xcode export and nothing in it asks Apple for one. Only the Account
Holder can create it — Xcode > Settings > Accounts > Manage Certificates,
`+`, Developer ID Application — and it expires on its own date, after which
a new one is made and exported the same way:

```sh
# Keychain Access > My Certificates > the Developer ID Application one >
# Export, as a .p12 with a password; then
base64 -i entoli.p12 | gh secret set MACOS_CERT_P12
gh secret set MACOS_CERT_PASSWORD
```

A DMG notarized before the expiry keeps opening after it.

## The publisher

A job of its own, so the one holding the keystore never also holds
`contents: write`. It is a matrix over the files the version job named, one
run per binary: handed several subjects, `actions/attest-build-provenance`
mints one bundle naming all of them, and a bundle on the release should be
about the file it sits beside. Each run attests its file and attaches the
pair — the App Bundle included, so the same check covers both channels:

```sh
gh attestation verify entoli-x86_64.AppImage --repo ByteRepair/entoli
```

`fail-fast: false`, since one entry failing should leave the others
attached, and `--clobber` is what makes re-running safe. A re-run attests
and re-attaches files already built and checked rather than trusting a
rebuild to match. **A job that never checks out has no git remote** —
`gh release upload` reads the repository from it and dies with `not a git
repository` pointing at the runner — so the publisher names the repository
explicitly.

`workflow_dispatch` takes a tag and rebuilds an existing release rather
than making anyone recreate one: recreating changes its timestamp and
notifies every watcher a second time.

## Google Play

`release.yml` calls `publish-play.yml` after the build, in parallel with
the publish matrix. The AppImage is installed as it is; the file sent to
Play is an input to something Google builds — the whole difference between
the channels.

**Play App Signing holds the project's own keystore, not a Google-generated
key, and that is what keeps the two channels interchangeable.** A
Google-generated key would carry a different signature than every APK
released so far and refuse to install over one, so moving either way would
start with uninstalling and losing chats, settings and workspace.
Uploading the project's key makes a move either way an ordinary update.
**A one-time, irreversible choice made when the app was created.**

**The first upload cannot come from here.** The Play Developer API refuses
to create an app's first release; a bundle goes up through the Console by
hand once, after which this workflow owns every release. No workflow can
detect and explain that state: it surfaces as an API error on a run that
otherwise looks correct.

Before the job works at all, none of it lives in this repository:

- a **service account** in a Cloud project with a JSON key, linked to the
  developer account by the grant below — and **Google Play Android
  Developer API** enabled on the project, if an upload says otherwise
- invited under the Play Console's **Users and permissions** with **Release
  apps to testing tracks** and, once production unlocks, **Release to
  production, exclude devices, and use Play App Signing** — both app-level,
  granted on Entoli. **Manage store presence** is not needed; release notes
  ride with the release
- the key stored as the repository secret **`PLAY_SERVICE_ACCOUNT_JSON`**;
  the job fails on an empty secret before downloading anything

That key is the one credential here that is cheap to lose: delete it in the
Cloud console and issue a new one in a minute. Rotate freely, on any doubt.

**Release notes are the GitHub release body, or nothing.** Play caps them
at 500 characters and rejects the upload rather than truncating, so a body
over the cap is dropped with a warning instead of cut. Only
`whatsnew-en-US` is written, the release body being English; a Greek
listing keeps what the Console holds.

A rejected upload is usually Console state no workflow can supply — the
data safety form, the content rating, a reachable privacy policy, the
target API level and the declarations tied to specific permissions —
which expires or tightens on Google's schedule rather than a release's.

**Production is locked, so releases go to Alpha.** A developer account
opened after 13 November 2023 needs a closed test with at least twelve
testers opted in for fourteen continuous days before production unlocks;
internal and open testing do not count, and a tester who opts out and back
in resets their clock, so everyone has to be in on the same day.
`publish-play.yml` therefore names `alpha`, the closed track Play creates
with the app, and **`TRACK` and `STATUS` move together** back to
`production` and `${{ inputs.publish && 'completed' || 'draft' }}` in one
edit when Play unlocks it; `publish` is inert until then.

### The application id cannot be a job output

`release-build.yml`'s AAB job parses the id out of Gradle and writes
`dist/package.txt` into the `aab` artifact, and `publish-play.yml` reads it
back. The long way round, because **GitHub drops a job output whose value
contains a registered secret's value** — the signing key alias is a
substring of `io.byterepair.entoli`, so the output would arrive at the
publisher empty and Play would reject an upload naming no package, which
reads as a Play misconfiguration. The only sign is one annotation on the
build job, `Skip output 'package' since it may contain secret`. Nothing
leaked: the masking was working, the alias being a poor secret — a
substring of an id public in Gradle and in every release.

The check applies to outputs crossing a job boundary, not to files, and not
to a step output inside a job where the secret is not in scope, so the id
survives the artifact and the publisher, which references none of the
`ANDROID_*` secrets. Parsing stays in the job that checks out and builds,
so the id uploaded under cannot drift from the id built with.