# Privacy Policy

Entoli is a chat harness for coding agents and language models on your
device. This policy describes what the app stores and what leaves your device.

## Data stored on your device

The app stores its data locally under its private data directory:

- **Conversations** — your messages, the agent's replies, tool calls and their
  results, and files you attach.
- **Settings** — the LLM providers you configure, including their API keys,
  the models you pick, the theme, and command environment variables.
- **Memory** — facts the agent extracts from conversations to recall in later
  ones, and the instruction files you write.
- **Workspace files** — files the agent creates or edits while running
  commands.
- **Reminders** — the name, time, and prompt of each reminder you set.

None of this leaves your device except as described below. Uninstalling the
app removes all of it. Backups are user-initiated exports to a local file the
user chooses.

## Data sent to third parties

The app has no server of its own. No analytics, telemetry, or crash reporting
runs in the app, and no data is sent to a server controlled by the app.

The following third parties receive data when you use the relevant features:

### LLM providers you configure

When you send a message, the app calls the LLM provider you have configured
directly. It sends the conversation as the model sees it: your messages,
attachment contents, tool results, recalled memories, and the system prompt.
The provider's own privacy policy applies to the data they receive. The app
calls their endpoint directly; there is no proxy or intermediary controlled by
the app.

### Web search

The agent's web search queries DuckDuckGo directly from your device over
HTTPS.

### Model, voice, and Linux downloads

Downloading an on-device model, a voice model, or a Linux rootfs makes a
request to the host that serves the file: Hugging Face for models and voice
recognition models, GitHub for voice synthesis models, and the Alpine Linux
CDN for the rootfs. The request includes your IP address and standard HTTP
headers, under the host's own privacy policy. The files are stored on your
device; inference and voice processing happen locally.

### Marketplace

Browsing the marketplace fetches its catalog and entry files from GitHub
Pages (`byterepair.github.io`), and the files of a remote entry from
`raw.githubusercontent.com`. The requests are plain GETs carrying your IP
address and standard HTTP headers, under GitHub's own privacy policy.
Installing an entry stores its files on your device; nothing else is sent.

Marketplace entries are the work of their publishers, not of the app's
authors, and installing one means using it under the licence its publisher
assigned. Entries the site publishes itself are AGPL-3.0; external entries
keep whatever their own authors gave them, and the app does not verify
licences — a skill shows one only where its SKILL.md names it.

### Android speech recognition and text-to-speech

Voice mode on Android uses the operating system's speech recognition and
text-to-speech services. These are OS services you choose. Depending on the
recognizer, audio may be processed on a server by that service's operator,
under that service's own privacy policy. The app prefers offline recognition
when an offline engine is available.

### Sync

Sync pairs two of your devices over an encrypted peer-to-peer connection. The
data transmitted is the conversation: messages, attachments, and metadata.

Sync traffic is end-to-end encrypted with ChaCha20-Poly1305 AEAD layered over
WebRTC DTLS. The encryption keys are derived from a pairing secret you
exchange out-of-band and never sent to any server.

Pairing rendezvous goes through a relay URL you supply (or over your local
network). The relay sees only opaque ciphertext and WebRTC signaling blobs; it
cannot read the conversation. If you use a TURN relay for network traversal,
it also sees only encrypted traffic.

## On-device model

The optional bundled model (llama.cpp) runs entirely on your device. Its
server binds to localhost and makes no network calls.

## Permissions

The app requests the following Android permissions, each used only for its
feature:

- **Microphone** — voice mode listening.
- **Camera** — scanning a sync pairing QR code.
- **Exact alarms** — firing reminders on time.
- **Boot-completed** — re-arming reminders after device restart.
- **Foreground service** — keeping the process alive while a turn runs, while
  voice mode is active, or while a model downloads.
- **Internet** — calling your configured LLM provider, web search, the
  marketplace, and sync.

No permission collects data in the background.

## Children

The app is not intended for use by children. It is recommended that a parent
or guardian supervise any use by a minor.

## Contact

For privacy inquiries, open a GitHub discussion at
<https://github.com/Yiannis128/agent-chat/discussions>.