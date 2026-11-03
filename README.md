<p align="center">
  <img src="Takku/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" alt="Takku icon" width="128">
</p>

<h1 align="center">Takku</h1>

<p align="center"><a href="https://takku.app">takku.app</a> · <a href="https://github.com/mameli/Takku/releases/latest"><b>Download the latest version</b></a> · macOS 15+ · Apple Silicon</p>

A macOS menu bar app that records your meetings, transcribes them **on your Mac** and writes the transcript and summary as **Markdown files in a folder you choose** (or your Obsidian vault). You pick who writes the summary: a model on your Mac, or any OpenAI-compatible provider you trust (for example one hosted in the EU).

Built as an alternative to Granola for people and companies that keep meeting audio and text on their Mac or in the EU.

- **Records both sides of a call**: your microphone and system audio (Meet, Zoom, Teams, any app).
- **Imports external recordings**: voice memos, lectures, in-person meetings or video files (*Import audio…*).
- **Tells speakers apart**: labels *Speaker 1*, *Speaker 2*… by voice, names them from the call or your calendar, and optionally remembers voices on your Mac.
- **Knows your calendar** (optional): names the note after the current event and lists invited participants.
- **Suggests when to record** (optional): notifies you when a call app takes or releases the microphone.
- **Transcribes locally** with NVIDIA Parakeet or OpenAI Whisper: the audio never leaves your Mac.
- **Summarises with a provider you pick**: Takku Credit (EU), Apple Intelligence, Ollama/llama.cpp/LM Studio on your Mac, or any OpenAI-compatible API. Or keep only the transcript.
- **Writes plain Markdown**: one meeting note (created at the start so you can take notes) plus a separate transcript file. Your own notes steer the summary.
- **Markdown Templates**: customise sections and instructions in `~/.takku/templates/`, or set `full_text: true` to rewrite an entire lecture instead of summarising it.
- **Screenshots in the note** (optional): `⌃⌥⌘S` captures the active window and embeds it under the matching summary point. Never sent to the model.
- **Custom Vocabulary**: fixes names, acronyms and jargon in the transcript and spells them right in the summary.
- **Hooks, MCP and CLI**: run a script after each meeting (Notion, Confluence, git), query your meetings from Claude, Codex, Cursor and other MCP assistants, or search them with `takku` in the terminal.

## Requirements

- A Mac with Apple Silicon and macOS 15 or later
- Disk space for the transcription model, downloaded on first use: about 630 MB for the default model (220 MB to 1.6 GB depending on the model)

Meetings can be in Italian, English, German, French, Spanish or 20 other European languages (*Settings → Transcription → Meeting languages*), one language per meeting. The summary can be written in any language.

## Install

1. With [Homebrew](https://brew.sh):
   ```sh
   brew install --cask mameli/takku/takku
   ```
   Or download `Takku-<version>.dmg` from the [latest release](https://github.com/mameli/Takku/releases/latest), open it and drag **Takku** into **Applications**.
2. Open Takku. It is notarized by Apple and lives in the menu bar, not in the Dock. Continue with [First setup](#first-setup).

**Updating**: run `brew upgrade --cask takku`, or quit Takku and replace it in Applications. Settings, profiles, API keys, permissions and downloaded models are kept. `brew uninstall --cask --zap takku` also deletes Takku's settings, recordings and models; your notes folder is never touched. See [CHANGELOG.md](CHANGELOG.md) for release notes.

**Coming from 0.x**: from 1.0 Takku is signed with an Apple Developer ID, so macOS treats it as a new app once. Re-allow microphone, system audio and calendar access, enter your password to let Takku read saved API keys (*Always Allow*), and turn *Open at login* back on if you used it.

## First setup

At first launch, a *Welcome to Takku* window walks you through these steps (reopen it anytime before choosing a folder via *Set up Takku…* in the menu, or configure each step later in *Settings*):

1. **Notes folder.** Choose *Use Documents/Takku* or any folder (such as your Obsidian vault); change it later in *Settings → Notes → Folder*. Takku creates `Meetings/`, `Meetings/Transcripts/` and `Meetings/Screenshots/` as you use it.
2. **Permissions.** Allow microphone and *System Audio Recording Only*. For screenshots (`⌃⌥⌘S`), also allow *Screen Recording* (optional; takes effect the next time Takku opens).
3. **Transcription model.** Downloaded and prepared once in a few minutes. If you skip it in the welcome window, it runs during your first meeting.
   In *Settings → Transcription* you can switch between:
   - **Parakeet Ultra** (default, 632 MB) and **Parakeet v3** (490 MB): the most accurate and fast; on short replies they can switch language.
   - **Whisper Large v3 Turbo** (646 MB), its **full** version (1.6 GB) and **Small** (217 MB): always write in the meeting's language.
4. **Open at login** (optional). Turn it on in the welcome window or in *Settings → General* from the copy in `/Applications`.
5. **Summary Profile.** Choose who writes the summary (or skip it to get only transcripts):
   - **Takku Credit**: prepaid credit for summaries, hosted in the EU with nothing kept. Buy a pack in the welcome window or at [takku.app/credit](https://takku.app/credit) and paste the key from the email.
   - **Ready-made profiles** in *Settings → Summary*: **Ollama** on your Mac (`ollama pull hf.co/ggml-org/gemma-4-E4B-it-GGUF:Q4_0`, started with `OLLAMA_CONTEXT_LENGTH=32768`), **Mistral**, **TensorX** and **OpenRouter** (just paste your API key, stored in the macOS Keychain, press *Test connection*, then *Use for Summaries*).
   - **Apple Intelligence** (macOS 26+ with Apple Intelligence on): free and on-device, with nothing to set up. Because its context window is small (8,192 tokens on macOS 27, 4,096 on macOS 26), long meetings are summarised in parts (~3 minutes per hour) and summaries are shorter than with a large model.
   - **Custom OpenAI-compatible server**: add a profile with name, base URL, model, max context (set to the server's real `-c` limit; plain `http://` is allowed only on `localhost`) and optional API key:

     | Provider | Base URL | Model | Key |
     |---|---|---|---|
     | llama.cpp on your Mac (`llama-server -hf ggml-org/gemma-4-E4B-it-GGUF:Q4_0 -c 32768`) | `http://localhost:8080/v1` | `ggml-org/gemma-4-E4B-it-GGUF:Q4_0` | none |
     | [Regolo.ai](https://regolo.ai) (Italy) | `https://api.regolo.ai/v1` | `gemma4-31b` | yes |
     | [Mistral](https://console.mistral.ai) (France) | `https://api.mistral.ai/v1` | `mistral-medium-latest` | yes |
     | [OpenRouter](https://openrouter.ai) (United States) | `https://openrouter.ai/api/v1` | `openai/gpt-6-luna-pro` (or any model) | yes |

   <details>
   <summary><b>Advanced profile options: Responses API, Reasoning and Extra parameters</b></summary>

   - **Responses API**: turn on *Use the Responses API* at the bottom of the profile for models that require it (such as some OpenAI models), keeping the same base URL.
   - **Reasoning**: sets how much the model thinks before answering (*Model default* sends nothing). OpenRouter adapts it to each model; other providers receive OpenAI's `reasoning_effort`.
   - **Extra parameters**: a JSON object merged into every request, overriding Takku's keys. For example, on [TensorX](https://docs.tensorx.ai/api-reference/reasoning), DeepSeek V4 enables reasoning with `{"chat_template_kwargs": {"thinking": true}}`, and Qwen 3.8 accepts `{"reasoning_effort": "xhigh"}` (while refusing *Off* and *High*). *Test connection* sends the same reasoning and Extra parameters as a summary so you can verify them right away.
   </details>

   > **Privacy note:** Takku does not check where a provider processes your data (for example, OpenRouter is outside the EU and routes requests to each model's provider). Check the provider's terms and your company's policy before using it for work meetings.

## Use

### During a meeting

- **Start / Stop (`⌃⌥⌘R`)** from any app or from the menu bar (change shortcuts in *Settings → General → Keyboard shortcuts → Change…*). While recording, the menu bar icon is a red dot and the menu shows the elapsed time.
- **Call suggestions** (optional, *Settings → General*): shows a notification to start when a call app uses the microphone for ~5 seconds (Zoom, Teams, Slack, FaceTime, Webex…) or a browser/chat app for ~15 seconds (Meet, WhatsApp…), and another to stop when the call ends. Dictation apps are ignored.
- **Take notes**: choose **Open note** in the menu (or turn on *Settings → Notes → Open the note when a meeting starts*) and write under **Personal notes**. Takku never overwrites them and uses them to guide the summary.
- **Mark a moment (`⌃⌥⌘M`)**: the menu bar dot flashes a star, the passage gets a ⭐ in the transcript, and the summary gives it priority.
- **Take a screenshot (`⌃⌥⌘S`)**: captures the active window (or full screen) and marks the moment. Takku embeds the image under the matching summary point and transcript passage (unmatched ones are listed after the summary) using the timestamps cited by the summary—the model never sees the image.
- **Silence warnings**: if the microphone or system audio is silent for 2 minutes, the menu warns you; if a track has been silent since the start, a notification tells you which permission to check.

### After a meeting

When you stop, Takku finishes transcribing, writes the summary at the top of the note, links the transcript, renames the note with a short title (unless named after a calendar event) and sends a notification.

- **Template & Summary Profile**: pick them in the menu before stopping or retrying. Choose **Transcript** as the profile to skip the summary (on Macs with Apple Intelligence, the note still gets a short local title).
- **Progress & timeouts**: the menu shows the current phase and elapsed minutes; *Stop processing* cancels it. External model requests time out after 10 minutes without a reply (15 minutes total per request block).
- **Recent meetings** submenu:
  - **Open note** / **Open Transcript**: open the files directly, or choose *Show all in Obsidian…* (*Show the notes folder in Finder…* without Obsidian).
  - **Name speakers…**: assign names to Speaker 1, Speaker 2… (see below).
  - **Regenerate Summary**: writes a new summary from the current transcript in your notes folder, using the Template and Profile currently selected in the menu.
  - **Reprocess Recording…**: rebuilds the transcript from the audio with your current Vocabulary and speaker names (reusing valid cached segments, or from scratch if you tick *Transcribe again from scratch*), then writes a new summary. If a retry fails, your previous summary and transcript are kept.
- **Report a problem…**: creates a diagnostic file (Takku version, Mac model, active models and the last 3 days of logs), reveals it in Finder and opens a pre-filled GitHub issue. Nothing is uploaded automatically.

### Calendar

Turn on *Settings → General → Use the calendar*: when a meeting starts during a calendar event (or if you pick another ongoing event from the *Calendar event* menu while recording), the note takes the event's title and lists invited people in `participants` to help the summary name speakers. If you edit `participants` in the note, the change is used the next time you regenerate the summary.

### Speaker names and voice recognition

If the summary cannot tell who a speaker is, choose *Recent meetings → Name speakers…*:
- Press **▶** next to a speaker to hear a few seconds of their voice (press again for another sample) alongside a quote from the transcript.
- Pick a name from the invited calendar participants or type one, then press **Save and Regenerate**.

You can also map speakers directly in the note's frontmatter and choose *Regenerate Summary*:

```yaml
speakers:
  - Speaker 1 = Mario Rossi
  - Speaker 3 = Anna Bianchi
```

 The transcript then shows *Mario Rossi (Speaker 1)* and the summary uses their names.

**Voice recognition** (*Settings → Transcription → Recognise voices*, off by default): Takku remembers named voices on your Mac only and suggests their names in future meetings for you to confirm. Because a voice is biometric data, enable it only with participants' consent. Manage or forget saved voices anytime in *Settings → Transcription*.

### Templates

Templates are Markdown files in `~/.takku/templates/` that define the summary's sections and instructions. Create or edit them from *Settings → Notes → Templates* (*New Template…*, or `⋯` → *Edit With*).

- **Summary language**: add `summary_language: en` (or `it`, `fr`…) to the frontmatter to force a language; otherwise it matches the meeting's language.
- **Full-text mode**: add `full_text: true` to rewrite the entire recording in clean prose instead of summarising it, processed in 10-minute blocks so the end stays as detailed as the beginning (avoid whole-meeting overview sections, as the template is applied to each 10-minute block).

Built-in and example templates in [`examples/templates/`](examples/templates/):
- [**Lecture**](examples/templates/Lecture.md) *(created on first launch)*: topic-by-topic study notes with definitions, LaTeX formulas, lecturer highlights, glossary and review questions.
- [**Full text**](examples/templates/Full%20text.md) *(created on first launch)*: complete lecture rewrite (`full_text: true`) keeping student questions in place and fixing recurring technical terms consistently.
- [**Tactical**](examples/templates/Tactical.md) & [**Governance**](examples/templates/Governance.md): minutes for Holacracy circles (checklists, metrics, project updates, tensions, next actions, and governance proposals/objections).

> Long meetings work best with a reasoning model: smaller models or low reasoning effort may shorten discussions or drop points.

### Vocabulary

Add names, acronyms and jargon that speech recognition mishears to `~/.takku/vocabulary.md` (*Settings → Notes → Edit Vocabulary With*). Write one entry per line—the correct term, optionally followed by `=` and misheard variants, and `|` with a brief description:

```markdown
- Kubernetes = cubernetes, kubernetis
- dbt = di bi ti | data transformation tool
- Holacracy
```

Variants are replaced as whole words in the transcript (avoid listing common everyday words as variants), and all terms are passed to the summary model. Changes apply to new meetings and to *Reprocess Recording…*.

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

To send finished meetings to Notion, Confluence, git or anywhere else, place an executable script at `~/.takku/hooks/after-processing` (a file with no extension, `chmod +x`, starting with a `#!` line such as `#!/bin/sh` or `#!/usr/bin/env python3`). When processing or a retry succeeds, Takku runs it in your notes folder with the paths of the note (`$1`) and transcript (`$2`):

```sh
#!/bin/sh
# $1: the meeting note, $2: the Transcript. Runs in the notes folder.
git add -A && git commit -qm "Meeting: $(basename "$1" .md)"
```

To run multiple hooks, keep each in `~/.takku/hooks/` and call them from `after-processing`. See **[takku.app/hooks](https://takku.app/hooks)** for details and a ready-made Notion sync script ([`examples/hooks/notion.py`](examples/hooks/notion.py)).

**Summarising with an existing CLI subscription:** if you already pay for GitHub Copilot, Claude Code or Codex, you can record with the *Transcript* profile and let a hook generate the summary via CLI (note that this bypasses Takku's Templates, Vocabulary prompt injection, speaker naming and auto-renaming). [`examples/hooks/copilot.sh`](examples/hooks/copilot.sh) runs Copilot CLI with all tools disabled on notes marked with `copilot: true` in their frontmatter—only mark customer meetings if you have consent to send their data.

### Your meetings in an AI assistant (MCP)

Ask any MCP-compatible assistant (Claude Code, Claude Desktop, Codex, Cursor…) questions across your meetings—e.g. *"what did we decide about the release with Mario last week?"* Takku 1.14.0+ includes a built-in read-only MCP server (`Takku` does not need to be running).

- **Claude Code** (run once):
  ```sh
  claude mcp add --scope user takku -- /Applications/Takku.app/Contents/MacOS/Takku mcp
  ```
- **Codex** (run once): the Takku plugin adds the MCP server and two skills, one that looks up what was said and one that prepares a brief for your next meeting with someone.
  ```sh
  codex plugin marketplace add mameli/Takku
  codex plugin add takku@takku
  ```
- **Claude Desktop** (*Settings → Developer → Edit Config*):
  ```json
  { "mcpServers": { "takku": { "command": "/Applications/Takku.app/Contents/MacOS/Takku", "args": ["mcp"] } } }
  ```

The assistant can list meetings (by date, title, folder or participant), search them (case- and accent-insensitive) and read notes and transcripts from `<notes-folder>/Meetings/` (pass `--notes-folder PATH` after `mcp` to use another folder). It never accesses audio or modifies files. Remember that any meeting the assistant reads is sent to its AI provider.

### Your meetings in the terminal

`takku` reads the same meetings from a terminal or a script, read only, without starting the app:

```sh
takku list --from 2026-10-01 --query mario     # meetings, newest first, with their ids
takku search release regression                # meetings containing every word, with the lines
takku get 11111111-2222-3333-4444-555555555555 --no-transcript
```

Add `--json` for scripts (the same fields the MCP tools return) and `--notes-folder PATH` for another folder; `takku help` lists every option. Homebrew installs `takku` with the app; otherwise link it once:

```sh
sudo mkdir -p /usr/local/bin && sudo ln -s /Applications/Takku.app/Contents/MacOS/Takku /usr/local/bin/takku
```

### Obsidian or another editor

Notes are plain Markdown. Takku opens them in Obsidian by default if installed (where `[[links]]` to transcripts work with one click), or in your system Markdown editor. You can pick another app (such as Zed or VS Code) in *Settings → Notes → Editor*:
- **Turn on autosave** in your editor (e.g. `"autosave": "on_focus_change"` in Zed), because Takku reads your *Personal notes* from disk when generating the summary.
- **Keep the notes folder open** as a project so the editor follows the file when Takku renames it after generating the summary.

### Where your data is

- **Notes & Transcripts**: `<notes-folder>/Meetings/` and `Meetings/Transcripts/` (plain Markdown).
- **Screenshots**: `<notes-folder>/Meetings/Screenshots/` (JPEG, ~0.5–1 MB each; never deleted or uploaded by Takku).
- **Templates & Vocabulary**: `~/.takku/templates/` and `~/.takku/vocabulary.md` (plain Markdown).
- **Audio**: `~/Library/Application Support/Takku/Models/` (models, downloaded once from Hugging Face) and `~/Library/Application Support/Takku/Recordings/` (~20 MB/hour, deleted after 7 days by default; configurable or kept forever in *Settings → Recordings*).
- **Known voices** (if *Recognise voices* is on): stored locally on your Mac; manage or forget them in *Settings → Transcription*.
- **Summary log**: `~/.takku/summary-log/` (one JSON file per summary with requests and replies, up to 5 MB, to help you tune Templates by adding a `comment` field and asking a trusted model for improvements). Never read back by Takku or included in bug reports; disable or delete in *Settings → Recordings*.
- **API keys**: stored in the macOS Keychain.
- **External requests**: only what you enable—your chosen Summary provider (receives transcript, personal notes, template, vocabulary terms and calendar participants; never audio or screenshots; Apple Intelligence stays on-device), your Hook script, your MCP assistant, and the daily GitHub update check (*Settings → About → Check for updates*, sends no personal data).

Recording a meeting may require the consent of the other participants: tell them, and follow the rules that apply to you.

## Development

### Build from source

1. Install Xcode 16 or later and open it once.
2. Clone the repository:
   ```sh
   git clone https://github.com/mameli/Takku.git
   cd takku
   ```
3. Configure code signing (see [Signing](#signing)): copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`.
4. Build and install:
   ```sh
   xcodebuild -project Takku.xcodeproj -scheme Takku -configuration Release -derivedDataPath build/DerivedData build
   cp -R build/DerivedData/Build/Products/Release/Takku.app /Applications/
   open /Applications/Takku.app
   ```

### Signing

macOS ties microphone and system audio permissions to the app's signature. Without `Config/Local.xcconfig`, builds are signed ad hoc and macOS prompts for permissions after every build. Two free ways to get a stable signature:

- **Self-signed certificate**: in *Keychain Access → Certificate Assistant → Create a Certificate…*, name it `Takku`, set Identity Type to *Self-Signed Root*, Certificate Type to *Code Signing*, tick *Let me override defaults* (validity: 3650 days), then double-click it and set *Trust → Code Signing* to *Always Trust*.
- **Apple ID Personal Team**: add your Apple ID in *Xcode → Settings → Accounts* and set your Team ID in `Config/Local.xcconfig`.

### Working on the code

```sh
xcodebuild -project Takku.xcodeproj -scheme Takku -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Takku.app
cd TakkuCore && swift test   # domain logic tests
```

- `Takku/` is the macOS app (capture, transcription, Vault, Settings, menu); `TakkuCore/` is a pure Swift package with domain logic and tests (no AppKit/AVFoundation).
- Architecture & specs: [docs/SPEC.md](docs/SPEC.md), glossary in [CONTEXT.md](CONTEXT.md), decisions in [docs/adr](docs/adr/), manual test checklist in [docs/TESTING.md](docs/TESTING.md).
- Localization: English in code, Italian, German, French and Spanish in `Takku/Localizable.xcstrings` (errors in `TakkuCore` are also looked up there and added by hand). Test another UI language with `defaults write app.takku.takku AppleLanguages -array it` (or `de`, `fr`, `es`).
- Releases: `scripts/release.sh` builds a Developer ID–signed and notarized Release, packages the DMG (`scripts/dmg/`), publishes the GitHub Release for `MARKETING_VERSION` (`Config/Base.xcconfig`) and updates the Homebrew cask ([mameli/homebrew-takku](https://github.com/mameli/homebrew-takku)). Never overwrite a published version (Homebrew verifies the DMG SHA-256). Pass `--dry-run` to stop after building the DMG.
- Logs: `log stream --predicate 'subsystem == "app.takku.takku"'` (live) or `log show --last 1h --predicate 'subsystem == "app.takku.takku"'`.
- Smoke tests (Debug builds only, require isolated `-vaultPath`, `-testSummaryBaseURL`, `-dataDirectory` and `-testTakkuFolder`): see `runSmokeTestIfRequested()` in `Takku/MeetingController.swift`.

## Support

Takku is free. If it is useful to you, you can [buy me a coffee](https://buymeacoffee.com/mameli.dev): it helps cover the costs of keeping Takku going.

## License

MIT, see [LICENSE](LICENSE).

Takku downloads and runs third-party models: OpenAI Whisper through [WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT); [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) by moondream (CC BY 4.0) and [NVIDIA Nemotron 3 Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization) (OpenMDW 1.1) converted by FluidInference and run through [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0); [Silero VAD](https://github.com/snakers4/silero-vad) (MIT) through FluidAudio. Echo removal is ported from [Hex](https://github.com/anomalyco/hex) (MIT).
