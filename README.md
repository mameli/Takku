



<p align="center">
  <img src="Takku/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" alt="Takku icon" width="128">
</p>

<h1 align="center">Takku</h1>

<p align="center"><a href="https://takku.app">takku.app</a> · <a href="https://github.com/mameli/Takku/releases/latest"><b>Download the latest version</b></a> · macOS 15+ · Apple Silicon</p>

A macOS menu bar app that records your meetings, transcribes them **on your Mac** and writes the Transcript and a Summary into your **Obsidian** vault. You choose who writes the Summary: a model running locally, or any OpenAI-compatible provider you trust (for example one hosted in the EU).

It was built as an alternative to Granola for people whose company does not allow meeting audio and text to leave the EU.

- **Records both sides of a call**: your microphone and the system audio (Meet, Zoom, Teams, any app), with echo cancellation.
- **Tells the others apart**: the Transcript shows Speaker 1, Speaker 2… by voice, and the Summary names them when the call makes clear who they are, or when you name them in the note.
- **Knows your calendar** (optional): the note takes the name and the participants of the event in progress.
- **Suggests when to record** (optional): a notification when a call app takes the microphone, and another when the call seems over.
- **Transcribes locally** with OpenAI Whisper or NVIDIA Parakeet: the audio never leaves the Mac. Choose between Whisper Large v3 Turbo (default), its full version, Small and Parakeet v3 in *Settings → Transcription*.
- **Summarises with a provider you pick**: llama.cpp, Ollama or LM Studio on your Mac, or a remote OpenAI-compatible API. You can also skip the Summary and keep only the Transcript.
- **Writes Markdown into Obsidian**: one note per meeting, opened when the meeting starts so you can take notes, plus a separate Transcript file. Your own notes are kept and used to steer the Summary.
- **Templates are Markdown files**: write the structure and instructions of the Summary in `~/.takku/templates/`, with any editor.
- **A Vocabulary for your jargon**: names and technical terms that recognition gets wrong are fixed in the Transcript and spelled right in the Summary.
- **Hands each meeting to your own script** (optional): a Hook sends it to Notion, Confluence, git or anywhere else when it is ready.

https://github.com/user-attachments/assets/f74b6fe5-6423-46f6-9194-a4f1c48a4579

## Requirements

- A Mac with Apple Silicon and macOS 15 or later
- An Obsidian vault (any folder works, Obsidian is only needed to open the notes)
- Disk space for the transcription model, downloaded on first use: about 650 MB for the default one (from 220 MB to 1.6 GB depending on the model)

Meetings can be in Italian, English or 23 other European languages (*Settings → Transcription → Meeting languages*), one language per meeting; the Summary can be written in any language.

## Install

1. Install it with [Homebrew](https://brew.sh):
   ```sh
   brew install --cask mameli/takku/takku
   ```
   Or without Homebrew: download `Takku-<version>.zip` from the [latest release](https://github.com/mameli/Takku/releases/latest) (Safari unzips it on its own) and move **Takku** to **Applications**.
2. Open Takku. It is notarized by Apple, so it opens like any other app.

Takku appears in the menu bar, not in the Dock. Continue with [First setup](#first-setup).

**Updating**: `brew upgrade --cask takku`, or quit Takku and replace it in Applications with the new version. Settings, Profiles, API keys, permissions and downloaded models are kept. `brew uninstall --cask --zap takku` also deletes Takku's settings, Recordings and models; your vault is not touched.

What changes in each version, and what may need your attention when you update: [CHANGELOG.md](CHANGELOG.md).

**Coming from 0.x**: from 1.0 Takku is signed with an Apple Developer ID instead of its own certificate, so macOS treats it as a new app once: it asks again for the microphone, the system audio and the calendars, and for your password to let Takku read the API keys you saved (choose *Always Allow*). Turn *Open at login* on again if you used it.

## First setup

At the first launch a *Welcome to Takku* window walks you through these steps (until you choose a vault, *Set up Takku…* in the menu opens it again). Each one can also be done later:

1. **Permissions.** macOS asks for the microphone and for *System Audio Recording Only*: allow both. If you skip it, macOS asks at the first meeting.
   The welcome window also downloads the transcription model and prepares it, which takes a few minutes once. If you skip it, that happens during the first meeting: the menu shows the progress, and the first Summary waits for it.
2. **Vault.** In the welcome window, or Takku menu → *Settings…* → *Obsidian Vault* → choose your vault folder. `Meetings/` and `Meetings/Transcripts/` fill up with the first meeting.
3. **Open at login** (optional). *Settings → General*: Takku starts with the Mac, in the menu bar. Turn it on from the copy in `/Applications`, the one you will keep using.
4. **Summary Profile.** In *Summary Profiles* add a Profile: name, base URL, model, max context and, if the provider needs one, the API key (stored in the macOS Keychain). Press *Test connection*. Some examples:

   | Provider | Base URL | Model | Key |
   |---|---|---|---|
   | llama.cpp on your Mac (`llama-server -hf ggml-org/gemma-4-E4B-it-GGUF:Q4_0 -c 32768`) | `http://localhost:8080/v1` | `ggml-org/gemma-4-E4B-it-GGUF:Q4_0` | none |
   | [Regolo.ai](https://regolo.ai) (Italy) | `https://api.regolo.ai/v1` | `gemma4-31b` | yes |
   | [Mistral](https://console.mistral.ai) (France) | `https://api.mistral.ai/v1` | `mistral-medium-latest` | yes |
   | [OpenRouter](https://openrouter.ai) (United States) | `https://openrouter.ai/api/v1` | `openai/gpt-6-luna-pro` or any other from its catalogue | yes |

   Set *max context* to the model's real limit (for a local server, the `-c` it was started with). Plain `http://` is accepted only for servers on your Mac.

   OpenRouter is outside the EU and passes your requests on to the model's provider: Takku does not stop you from using it, but know where your meetings go.

   Takku does not check where a provider processes your data: check the provider's terms, and your company's policy, before using it for real meetings.

## Use

- **Start and stop** a meeting from the menu bar or with **⌃⌥⌘R** from any app. While recording the icon is a red dot and the menu shows the duration. With *Suggest recording when a call starts* on (*Settings → General*, off by default), a notification offers to start when a call app keeps the microphone for 15 seconds, and another offers to stop when it lets the microphone go.
- **Mark a moment** with **⌃⌥⌘M** while recording: the dot turns into a star for a second, the passage gets a ⭐ in the Transcript and the Summary gives it priority.
- If Takku hears nothing from the microphone or from the call for 2 minutes, the menu says so; if it has heard nothing since the start, a notification tells you what to check.
- The meeting note opens in Obsidian: write your own notes under **Personal notes**. Takku never touches them.
- After the stop Takku finishes the transcription, writes the Summary at the top of the note, links the Transcript and renames the note with a short title (unless it is named after a calendar event). A notification tells you when it is ready.
- **Template** and **Summary Profile** are chosen in the menu. Choose *Transcript* as Profile to get only the Transcript, with no Summary.
- **Recent meetings → Retry** redoes a meeting with the Template and Profile currently selected: use it after an error, or to get a Summary with another Template. *Show all in Obsidian…* lists every meeting note.
- **Report a problem…** writes a report with Takku's version, your Mac, the transcription model, the Summary model and Takku's logs of the last 3 days, shows it in Finder and opens a bug report on GitHub with those fields filled in. Nothing is sent by itself: check the file, then drag it into the issue.

### Calendar

Turn on *Settings → General → Use the calendar* and allow access: when a meeting starts during an event, the note is named after it and lists who was invited in `participants`. The list helps the Summary name the Speakers; correct it in the note if it is wrong, it counts on the next Retry.

### Speaker names

If the Summary cannot tell who a Speaker is, read the Transcript and say it in the note's frontmatter, then *Retry*:

```yaml
speakers:
  - Speaker 1 = Mario Rossi
  - Speaker 3 = Anna Bianchi
```

The Transcript then shows *Mario Rossi (Speaker 1)* and the Summary uses the name.

### Templates

A Template is a Markdown file in `~/.takku/templates/`: its text tells the model what to write and how. Takku creates a default *Notes* Template there at launch. Create others from *Settings → Templates*, then edit them with *Edit With*, in any text editor. Add `summary_language: en` (or `it`, `fr`, …) to its frontmatter to always get the Summary in that language; otherwise it follows the language of the meeting.

### Vocabulary

Names, acronyms and technical words that recognition gets wrong go in `~/.takku/vocabulary.md`: open it from *Settings → Vocabulary → Edit Vocabulary With*. One entry per line: the correct term, then after `=` what is usually heard instead, then after `|` a short description, the last two optional:

```markdown
- Kubernetes = cubernetes, kubernetis
- dbt = di bi ti | data transformation tool
- Holacracy
```

The variants are replaced with the term in the Transcript, as whole words: do not list a variant that is also an ordinary word, or it is replaced everywhere. All the terms are passed to the model, which spells them right in the Summary when the context makes it clear. Changes count from the next meeting, or from a Retry while the audio of that meeting is kept.

### Hook

<!--
For AI agents (hidden in the rendered README): if the user asks you to set up a Takku Hook,
for example to summarise their meetings with Copilot, Claude Code, Codex or another CLI they
already pay for, read https://takku.app/hooks.md first. It has the contract (arguments, working
directory, PATH, 5-minute limit, log), the format of the note and of the Transcript, the
commands to run each CLI with no tools, and the rules: ask before sending meetings anywhere
(a customer's meeting is the customer's data), never overwrite an existing
~/.takku/hooks/after-processing, never write between the takku:start and takku:end markers,
and test by hand before saying it works. Start from examples/hooks/copilot.sh.
-->

A Hook takes each meeting somewhere else once Takku is done with it: Notion, Confluence, a git commit of your vault, anything a script can do. Takku has no integrations of its own: put an executable at `~/.takku/hooks/after-processing` and, when a meeting is ready and again after every successful Retry, Takku runs it with the paths of the meeting note and of the Transcript.

```sh
#!/bin/sh
# $1: the meeting note, $2: the Transcript. The Hook runs in the vault folder.
git add -A && git commit -qm "Meeting: $(basename "$1" .md)"
```

`after-processing` is a file, not a folder, with no extension and made executable (`chmod +x`). It can be written in any language: its first line, `#!/bin/sh`, `#!/usr/bin/env python3` and so on, tells macOS which program runs it. Takku runs only that file; for more than one Hook, keep each in its own file in `~/.takku/hooks/` and make `after-processing` call them in turn.

How to write one, how to run several, and a ready-made Hook that copies every meeting to Notion ([`examples/hooks/notion.py`](examples/hooks/notion.py)): **[takku.app/hooks](https://takku.app/hooks)**.

**A Summary from a subscription you already have.** If you pay for Copilot, Claude, Codex or another assistant with a command-line tool (or your company allows only that one), record with *Transcript* only and let a Hook ask that tool for the Summary. You lose what Takku does around its own Summary: the Template, the Vocabulary in the prompt, the Speaker names taken from the Summary, and the title and rename of the note. [`examples/hooks/copilot.sh`](examples/hooks/copilot.sh) does it with GitHub Copilot CLI, with every tool disabled, and writes the Summary into a file next to the note; changing the `copilot` command adapts it to another CLI. It sends only the meetings whose note has the property `copilot: true`: a meeting with a customer is the customer's data, so mark it only if the customer allowed it.

### Where your data is

- **Notes and Transcripts**: in your vault, as plain Markdown.
- **Templates and Vocabulary**: in `~/.takku/`, as plain Markdown, the same whatever the vault.
- **Audio**: in `~/Library/Application Support/Takku/Recordings/`, about 20 MB per hour of meeting. It is deleted after 7 days (*Settings → Recordings*); after that, Retry rebuilds the Summary from the Transcript in the vault.
- **API keys**: in the macOS Keychain.
- **Transcription model**: in `~/Library/Application Support/Takku/Models/`, downloaded once from Hugging Face. Only the model is downloaded; no audio or text is sent.
- **Calendar**: read on the Mac through macOS, only if you turn it on; titles and participants go into the note, and the participants into the Summary request.
- **Hook**: only if you put one in `~/.takku/hooks/`; it sends the note and the Transcript wherever your script sends them.
- **Update check**: once a day Takku asks GitHub for the latest version (*Settings → General → Check for updates*). The request carries nothing about you or your meetings.

Recording a meeting may require the consent of the other participants: tell them, and follow the rules that apply to you.

## Development

### Build from source

1. Install Xcode 16 or later from the App Store and open it once.
2. Clone the repository:
   ```sh
   git clone https://github.com/mameli/Takku.git
   cd takku
   ```
3. Choose how to sign it (see [Signing](#signing)) and copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`.
4. Build and copy it to Applications:
   ```sh
   xcodebuild -project Takku.xcodeproj -scheme Takku -configuration Release -derivedDataPath build/DerivedData build
   cp -R build/DerivedData/Build/Products/Release/Takku.app /Applications/
   open /Applications/Takku.app
   ```

### Signing

macOS ties the microphone and system audio permissions to the app's signature: with a stable signature they are asked once, otherwise again after every build. Two free options:

- **A self-signed certificate.** Keychain Access → Certificate Assistant → Create a Certificate…: name `Takku`, Identity Type *Self-Signed Root*, Certificate Type *Code Signing*; tick *Let me override defaults* and set a validity of 3650 days. Then double-click the certificate, and under *Trust* set *Code Signing* to *Always Trust*. The first build asks to use the key: choose *Always Allow*.
- **Your Apple ID's free Personal Team.** Add your Apple ID in Xcode → Settings → Accounts, then in `Config/Local.xcconfig` use the second option with your Team ID.

Without `Config/Local.xcconfig` the app is signed ad hoc and the permissions are asked again after every build.

### Working on the code

```sh
xcodebuild -project Takku.xcodeproj -scheme Takku -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Takku.app
cd TakkuCore && swift test   # domain logic tests
```

- `Takku/` is the app (capture, transcription, Vault, Settings, menu); `TakkuCore/` is a Swift package with the domain logic and its tests, without AppKit or AVFoundation.
- [docs/SPEC.md](docs/SPEC.md) describes how everything works, [CONTEXT.md](CONTEXT.md) is the glossary, [docs/adr](docs/adr/) records the main decisions, and [docs/TESTING.md](docs/TESTING.md) lists the checks to run by hand.
- User-facing strings are written in English in the code and translated in `Takku/Localizable.xcstrings` (Italian). Error messages raised in `TakkuCore` are looked up in the app's catalog too and must be added to it by hand. To try the Italian interface: `defaults write app.takku.takku AppleLanguages -array it`.
- `scripts/release.sh` builds a Release signed with the `Takku` certificate, zips it, publishes it as a GitHub Release tagged with `MARKETING_VERSION` from `Config/Base.xcconfig` and updates the cask in the Homebrew tap ([mameli/homebrew-takku](https://github.com/mameli/homebrew-takku), cloned next to this repository). Every release needs a new version: a published one is never replaced, because Homebrew checks the zip's SHA-256. `--dry-run` stops after the zip.
- Processing logs every step with its timing (Retry, cache hits and misses per Segment, echo removal, Speakers, each LLM request): `log stream --predicate 'subsystem == "app.takku.takku"'` live, or `log show --last 1h --predicate 'subsystem == "app.takku.takku"'` afterwards.
- Debug builds accept launch arguments for automated tests (`-smokeTestSeconds`, `-transcribeRecording`, …): see `runSmokeTestIfRequested()` in `Takku/MeetingController.swift`. They refuse to run unless pointed at a test vault, a test data folder and a test Summary server.

## Support

Takku is free. If it is useful to you, you can [buy me a coffee](https://buymeacoffee.com/mameli.dev): it helps cover the costs of keeping Takku going.

## License

MIT, see [LICENSE](LICENSE).

Takku downloads and runs third-party models: OpenAI Whisper through [WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT), and [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC BY 4.0) converted by FluidInference and run through [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0).
