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

## The DMG

`tool/macos/make-dmg.sh <app> <output.dmg> [--sign identity]` is the packaging
shape the AppImage's is: staging of app and `/Applications` symlink, one
artifact out, `hdiutil` naming the volume after the app. The build produces a
universal binary, ad-hoc signed. An ad-hoc build runs on the machine that made
it and on another Mac through Finder's right-click Open, which is what an
unsigned DMG asks of whoever downloads one; `--sign` adds the Developer ID
identity under hardened runtime (`--deep` re-signs the engine and plugin
frameworks Flutter left ad-hoc), and notarization is the distribution step
after: `xcrun
notarytool submit` on the DMG, `xcrun stapler staple` the same file, the image
being notarizable whole so the ticket travels inside it. CI builds the
unsigned DMG until enrollment; the job grows the signing identity and the
notarytool profile when it happens.

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