# The macOS half

## Why no sandbox

The one thing this platform was not going to get for free is App Sandbox. The
agent's contract is commands on the machine, exec'd with `Process.start` —
`bash`, `git`, whatever the user has. Under App Sandbox that entitlement soup
must all be written down before the first launch, and nothing about it can be
requested as the agent asks: entitlements live in the code signature, widening
the sandbox at runtime means re-signing, and a denied path is a failed
`Operation not permitted`, not a dialog — Powerbox grants exist only where the
app itself asks with an open panel first. Sandbox or not is therefore the
decision the rest follows, and it came out unsandboxed, which is also what
every agent that ships runs on a Mac does: the app is not sandboxed; the
permissions are the app's own approvals; the OS-level isolation anyone has is
a per-command child sandbox built by the helper. If this platform ever grows
the third, macOS's answer is Seatbelt (`/usr/bin/sandbox-exec` with a profile
the helper writes), which is the exact slot `platformDriver` already keeps for
Linux's Landlock helper.

## The entitlements

Both `DebugProfile.entitlements` and `Release.entitlements` are generated files
reduced to nothing: Release is an empty dict, DebugProfile keeps only
`com.apple.security.cs.allow-jit`, since a debug build runs the VM with a JIT
and a future hardened-runtime debug signing would want it. Signing under
hardened runtime with no entitlements is the release story: `make-dmg.sh
--sign` does it and the sandbox never re-enters through the signature by
accident. The Mac App Store — which requires the sandbox — is planned for
when enrollment happens, as a second entitlements file (`app-sandbox`,
`network.client` + `network.server` for the sync hub,
`files.user-selected.read-write` for a workspace grant made once per project)
behind an Xcode configuration of its own, not as a fork of this one. That
build re-enters the Powerbox territory deliberately, since a MAS archive
cannot ship without it.

The deployment target is 12.0, not the 10.15 the 3.44 template generated:
current Xcode refuses anything below 12.0 outright, so the number says what
the toolchain will build rather than what the app needs.

## What a command runs on

The host, and that is all. No proot — W^X is Android's problem and the bundled
tools are that platform's answer to it — and no rootfs: `deviceAbi` answers
null here the way it does in a browser, which is what hides the Terminal
page's catalog. A macOS turn is a Linux-desktop-with-no-Linux-installed turn:
`LocalShell`'s host driver, the machine's real `HOME`, the user's own tools on
PATH. The login-PATH capture covers it the same way (`$SHELL` as a login
shell, macOS's zsh on the list).

## What is absent, and honestly so

No on-device models: the bundled llama.cpp server is built for Android and
Linux and never for this platform, so `platformLocalLlm` answers
`UnavailableLocalLlm` here and the On-device page says so — the same wording a
Linux build that skipped `build-llama.sh` gets. The plan for this platform is
not llama at all: Apple Intelligence's FoundationModels, reached through a
Swift plugin of the app's own, on macOS 26 and later — a future version, at
which point the settings page is where the story changes and nowhere else.

The keyring is the file fallback (`KeyringSecretStore` probes a Secret Service
through the session bus, which macOS does not run), and reminders take the app
live timers — a reminder the app was closed through is caught up at the next
launch, as on Windows and in a browser. Neither says anything different from
an absence; nothing crashes over either.

## Voice mode

The stock implementations — sherpa-onnx and audioplayers both carry macOS
plugins, and `record` ships a macOS recorder — so there is no recorder
registration and nothing to swap: `registerRecorder` is a no-op here the way
it would be on any platform without a fallback to install. What the mic costs
is one prompt: `NSMicrophoneUsageDescription` in `Info.plist` is the text TCC
reads, the only permission a macOS build asks for.

## The icon

`Runner/entoli.icon` is the app icon's Icon Composer package — the layered
format iOS 26 and macOS 26 render as Liquid Glass — one file for both
platforms (`ios/Runner/entoli.icon` pointing into this tree through a
symlink), its layers generated from `assets/icons/cookie.svg` with the
squircle mask and the shadows left for the system: square layers only, the
glass look is composed by the OS on top. The format's rules, the wiring and
what was verified from where live in a AGENTS.md inside the package itself.
The `prompt` icon has no macOS copy, the way it has no PWA one.

## The DMG

`tool/macos/make-dmg.sh <app> <output.dmg> [--sign identity]` is the packaging
shape the AppImage's is: staging of app and `/Applications` symlink, one
artifact out. The volume takes the app's name plus Installer — "Entoli
Installer" — so what a user sees mounted reads as the thing being installed,
not the app itself; the staged item inside stays `<Name>.app`. The build
produces a universal binary, ad-hoc signed. An ad-hoc build runs on the
machine that made it and on another Mac through Finder's right-click Open,
which is what an unsigned DMG asks of whoever downloads one; `--sign` adds
the Developer ID identity under hardened runtime (`--deep` re-signs the
engine and plugin frameworks Flutter left ad-hoc), and notarization is the
distribution step after: `xcrun
notarytool submit` on the DMG, `xcrun stapler staple` the same file, the
image being notarizable whole so the ticket travels inside it. CI builds the
unsigned DMG until enrollment; the job grows the signing identity and the
notarytool profile when it happens.

The window a user's mount opens with comes from committed data, not from any
styling run at package time. One styling session on this Mac — a throwaway
volume laid out by `dmg-layout.applescript` run against it — had its
`.DS_Store` harvested and committed as `tool/macos/dmg-window.dsstore`
(deliberately named nothing like `.DS_Store`: Finder parses the file only in
the volume it is copied into). The background that session bound is committed
beside it: `dmg-background.tiff`, two images per screen scale merged by
`tiffutil -cathidpicheck` from `dmg-background.swift`'s renders — which types
`cookie.svg`'s `bgGrad` stops, and is the authoring tool the pair of them
regenerate from; a single 2x PNG once rendered unscaled and cropped, which is
why the layering. `make-dmg.sh` copies the pair into the staging volume
(`.DS_Store`, `.background/background.tiff`), stages the bundle's `.icns` as
`.VolumeIcon.icns` — found in the bundle rather than named, the `.icon`
package being the authority for that string, with an absent one a line and
not a failure — then creates the UDRW, attaches it read-write once to set the
custom-icon flag (`SetFile -a C`: a headless step, set on the flow's own
mounted volume so it survives the convert — read back verified on the shipped
artifact), detaches, and converts to the shipped UDZO. No Apple events, no
measurement, no math at package time: a CI runner without Finder makes the
same DMG this Mac does. There is nothing to fall back from — the layout is
committed data, so every missing piece is one `[dmg]` line and a failed run.

The capture recipe, for when the look itself changes: stage the app, the
symlink, the background, the icns; create a UDRW; attach it read-write; run
`tool/macos/dmg-layout.applescript` with the design's numbers; wait for the
volume's `.DS_Store` to appear, then copy it to `tool/macos/dmg-window.dsstore`;
detach — the shipped DMG comes from `make-dmg.sh` after that, not from the
capture session. The numbers are the design's, once each, and carry two
Finder facts learned by screenshot: `position` is the point an icon centers
on, not a cell's top-left, so `Entoli.app` goes at {180, 243} and
Applications at {420, 243} with their visual centers on the arrow line 65%
down the artwork (the 17pt ride is the label Finder hangs under each 96pt
glyph); the window content is 600x400 placed at {20, 20} — near the origin,
where every screen finds it — which Finder recorded as `{20, 33}` through
`{620, 463}`, its own margin. And nothing in the artwork is ever drawn in a
flipped space: the texts convert baseline y as `h - y`, and a stroke that
forgets paints 24pt off its row. The window size reasserts itself on every
open; nothing locks it against a user resizing it once open.

All of it stays on hdiutil even though macOS 27 deprecates it for
`diskutil image`, because the new verb is the one that fails intermittently
here — same staging, same command, exit 156 flipping run to run with nothing
public about the code — where hdiutil has been reliable; only its
deprecation notice is swallowed, everything else it says comes through.

## Tests on this host

The suite runs real processes through the host's real shell, so a macOS host
fails eighteen tests before this branch does anything: the recorder
registration (`LinuxRecorder` is Linux's registration), the Byte Repair bin
directory and setup gate (`Platform.isLinux` gates the store behind them), the
skills install's chmod acquire-and-release (the guard is off for macOS
deliberately), and the whole persistent-shell session contract. They are the
host's answer, not regressions, and CI on Linux is what gates the branch —
verified by the same five files failing with the same eighteen on master.
Everything else, and everything the harness fakes, passes here.