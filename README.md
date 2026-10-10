# Byte 🦖

Byte is a macOS companion that sits below the notch or wherever you drag it.
It combines a pixel-art T-rex, a virtual-pet care loop, and streaming chat through
the Anthropic API.

## Requirements

- macOS **14 or newer**
- Xcode or its command-line tools, with Swift **5.9 or newer**
- An Anthropic API key for chat; the pet works without one

## Run from source

```bash
swift run
```

Click Byte to open chat. Paste your Anthropic API key into the connection form.
Byte stores newly entered keys in your Mac's **Keychain** and reports storage
failures. API usage is billed to your Anthropic API account separately from a
Claude subscription.

An `ANTHROPIC_API_KEY` environment variable overrides the saved key. Existing
`~/.config/byte/api_key` installations are migrated into Keychain; the plaintext
file is removed only after Keychain access succeeds. The old `~/.config/finn`
directory is migrated when no Byte directory exists. Failed migration keeps the
old file and shows an error.

Unsigned rebuilds can cause macOS Keychain access prompts when the executable
changes. Stable code signing is recommended for distribution.

## Build an app bundle

```bash
./bundle.sh
mv Byte.app /Applications/
```

The script assembles `Byte.app` with a release executable and the provided icon.
Launch the installed app, then use Settings to enable launch at login, or add it
in System Settings → General → Login Items. This requires an installed bundle;
it is unavailable to `swift run`.

The bundle is unsigned. For a locally built copy, use Finder's Open action and
follow macOS's prompts if needed.

## Use Byte

- **Click** Byte to open or close chat; **drag** him to move and pin his position.
- **Hover** to feed, give water, or play. The care panel also offers rest.
- **Ask a question**, then press Return or the send button. Replies stream with
  markdown, copyable code blocks, and web-search source links.
- **Stop reply** interrupts a response or retry. Interrupted text remains visible
  with a status message and is excluded from future assistant history.
- **Drop or paste an image**, or use the clipboard button, to attach it to the next
  question. Images are resized and saved beside the conversation. Sonnet, Opus,
  and Haiku 4.5 accept image input.
- **New chat** saves the current thread before clearing it. **Saved chats** opens
  the archive browser. A save failure keeps the current conversation available.
- **Settings** controls model, effort, web search, sound, check-ins, and login.
  Haiku uses standard generation; adaptive effort applies to Sonnet and Opus.
  Changes apply to the next message.
- **Right-click** for chat, tricks, care, saved chats, position reset, sign out,
  and quit.

Byte cannot draw inside the notch's physical cutout. The window sits below it and
falls back to the top of the main display on Macs without a notch.

## Data and cost

Conversations, pet needs, archives, and image sidecars are stored locally under
`~/.config/byte`. API keys entered in the app are stored in Keychain. Chat text and
attached images in the active thread are sent to Anthropic when you ask a question.

The latest prompt is saved before networking. Streaming text is checkpointed
about once per second and saved at completion or cancellation. Unreadable history
is copied to a `history-recovery-*.json` file before new history is written.
Keep those files if you need to recover a conversation.

The session cost meter uses reported token/search counts and approximate prices
in the source. It includes known usage from failed attempts, but is **not an
invoice**: cache pricing, usage lost during a disconnect, and provider price
changes affect actual charges. Web search is capped at five uses per request.
Long threads resend more context and can increase cost.

Deleting an archive currently leaves image sidecars on disk. There is no
automatic retention limit or conversation summarization yet.

## Development and checks

```bash
swift build
swift test
./bundle.sh
plutil -lint Byte.app/Contents/Info.plist
```

GitHub runs these checks on macOS 14. Tests use temporary directories, an
in-memory key store, and stubbed HTTP streams; they do not use your Keychain or
call Anthropic. AppKit, SwiftUI, Security, and AVFoundation require macOS; Linux
syntax checks cannot establish that the app builds or works on a Mac.

- `Sources/Byte/App.swift`: lifecycle and window positioning
- `Sources/Byte/ByteModel.swift`: chat, persistence, archives, and pet state
- `Sources/Byte/AnthropicRequest.swift`: request capabilities and usage counts
- `Sources/Byte/APIKeyStore.swift`: Keychain storage
- `Sources/Byte/ByteView.swift`: chat, care, settings, and animation views
- `Sources/Byte/ByteSprite.swift`, `Props.swift`, `Quips.swift`, `Sound.swift`: pet art,
  props, personality, and synthesized audio
- [Code review and improvement priorities](docs/CODE_REVIEW.md)
- [Roadmap](BYTE_ROADMAP.txt)
