# Changelog

What changes in each version of Takku, newest first. **Before you update** lists what needs your attention, when there is something. Downloads: [GitHub Releases](https://github.com/mameli/Takku/releases).

Takku was called Steno up to 0.2.1.

## 1.12.0 (2026-10-30)

- **Recent meetings, clearer actions**: *Retry* is replaced by *Regenerate Summary*, which always writes the Summary again from the Transcript in your Vault (your corrections included, even while the audio is still there), and *Reprocess Recording…*, which rebuilds the Transcript from the audio after asking, because it replaces the edits you made to it. It reuses what was already transcribed when still valid, so a new Vocabulary word or Speaker name is applied in seconds; tick *Transcribe again from scratch* to redo it all, voices included. The notification says which of the two happened. *Open Transcript* opens it directly, and a failed meeting shows its error in its own submenu.
- **Name speakers**: *Recent meetings → Name speakers…* opens a small window with a field for each Speaker of the Transcript and the calendar's invited participants as suggestions. To tell who is who, each Speaker shows the first words of what they say and, while the audio is kept, ▶ plays a few seconds of their voice; press it again for another passage. *Save and Regenerate* writes the names in the note and a new Summary. Editing `speakers` in the frontmatter still works.
- **Recognises voices you have named** (off by default, *Settings → Transcription → Recognise voices*): when you name the Speakers, Takku remembers their voices on your Mac and, in the next meetings, fills in the name of a voice it recognises in *Name speakers…*, marked *Recognised by voice* for you to check before saving. Voices are only computed while the audio is kept. A voice is biometric data, so turn it on only for people who agreed; Settings lists the voices remembered and forgets one or all. The first time it downloads a model of about 22 MB.
- **What Takku is doing**: while it works, the menu shows the meeting and its phase: transcribing (part N of M), identifying speakers, writing the Summary (part N of M on a long meeting), merging it. Importing several files shows which one is being converted.
- **Your own keyboard shortcuts**: *Settings → General → Keyboard shortcuts* changes or removes the shortcuts to start or stop a meeting, mark a moment and take a screenshot (by default still ⌃⌥⌘R, ⌃⌥⌘M and ⌃⌥⌘S). Useful when another app already uses one. The menu shows the shortcuts in use on the right.
- **Screenshots of the active window**: ⌃⌥⌘S takes only the window you are looking at, not the whole screen with the menu bar and everything else open. A window in full screen, like a shared presentation, is taken whole.
- **Templates for Holacracy meetings**: [`Tactical`](examples/templates/Tactical.md) and [`Governance`](examples/templates/Governance.md) in `examples/templates`, to copy into `~/.takku/templates/`. Complete minutes in the meeting's language: every tension or proposal with its discussion, every action as a checklist, adopted texts as close to verbatim as possible.
- **The note no longer opens by itself** when a meeting starts, so Obsidian does not jump in front of the call. Open it with *Open note* in the menu while recording, or turn on *Settings → Notes → Open the note when a meeting starts* to have it as before.
- **A failed attempt no longer erases a good Summary**: if *Regenerate Summary* or *Reprocess Recording…* fails (no internet, provider error), the previous Summary and Transcript stay in the Vault; the error is in the menu and in the notification.
- **Imported files**: the note says the recording is queued instead of *Recording in progress*; an old memo imported now appears first in *Recent meetings*, and its audio is kept for the full period from the import, not from when it was recorded. If parts of the file could not be read, the notification says which seconds were skipped.
- **Safer with your data**: if Obsidian Sync leaves two copies of a note or Transcript with the same ID, Takku tells you which files instead of updating one at random. Without a Vault the Transcript is never deleted with the audio, since it is the only copy, and the notification opens it. A damaged Recording folder is reported once and its audio kept, never cleaned up. The daily cleanup no longer reads every Transcript in your Vault for every past meeting. A screenshot taken just before *Stop* is no longer lost.

## 1.11.1 (2026-10-27)

- **Takku's icon in Mission Control**: while Settings or the welcome window is open, Takku shows up like any other app, with its icon in the Dock, in ⌘-Tab and under its window in Mission Control (useful with *Group windows by application* on). When you close the window it goes back to the menu bar only.

## 1.11.0 (2026-10-27)

- **Better at telling the voices apart**: Takku now uses NVIDIA's Nemotron 3 Diarization, free and on your Mac like the previous one. On real meetings it no longer splits one person into two Speakers, keeps apart someone who speaks rarely, and gives a Speaker to short replies that used to stay as *Others*. Up to 8 voices per meeting. The model is about 190 MB, downloaded once at the first meeting with other people; the previous one is deleted. *Retry* on a meeting that still has its audio tells its voices apart again.
- **Import audio** no longer gives up on a video whose sound macOS cannot read in a few points (seen on files exported with ffmpeg): it reads the rest and leaves a short silence where it could not.

## 1.10.0 (2026-10-25)

- **Import audio**: *Import audio…* in the menu turns a recording made elsewhere into a meeting, without recording it again: a voice memo from your iPhone, a lecture, an in-person meeting, a call recorded by another app. Any audio format macOS reads works (m4a, mp3, wav…), and videos too (mp4, mov: only the sound is used), several files at once. Takku transcribes it on your Mac, tells the voices apart and writes the Summary as for a call. The note takes the date and time the file was recorded, and the calendar event of that moment. The file itself is left where it is.
- **Full text instead of a summary**: a Template with `full_text: true` in its header gets the whole meeting rewritten, cleaned up but complete, for example the full text of a lecture to study from. Takku writes it ten minutes at a time and joins the parts, so the end of a long lecture is as detailed as the beginning.
- **Parakeet Ultra is the default transcription model** for new installs: the most accurate, and fast. If you never chose a model, you keep Large v3 Turbo, already on your Mac; to switch, *Settings → Transcription*.
- **Tidier Settings**: one tab per subject (General, Notes, Transcription, Summary, Recordings) instead of one long page, and the actions of each row in a ⋯ menu instead of a row of buttons. Models still to download have a download icon, and how long the audio is kept is a menu of days, with *Forever* too.
- **Templates for lectures**: two examples to copy into `~/.takku/templates/`: [Lecture](https://github.com/mameli/Takku/blob/main/examples/templates/Lecture.md) for study notes and [Sbobina](https://github.com/mameli/Takku/blob/main/examples/templates/Sbobina.md) for the full text of a lecture.

## 1.9.0 (2026-10-24)

- **Takku Credit**: summaries with nothing to set up. Buy a pack at [takku.app/credit](https://takku.app/credit), paste the key from the email into the *Takku Credit* profile in *Settings → Summary Profiles*, then press *Use for Summaries*. The profile shows how much credit is left, and *Add credit…* buys another pack for the same key. It's optional and prepaid, with a model hosted in the EU: Takku stays free and works with any provider you choose. A new install finds it first among the ready-made profiles; if you already have profiles, press *Add Takku Credit*.

## 1.8.1 (2026-10-23)

- **Disk image**: Takku now comes as a `.dmg` instead of a zip. Open it and drag Takku into Applications. With Homebrew nothing changes.
- **Ready-made Summary Profiles**: a new install finds four in *Settings → Summary Profiles*: Ollama (Gemma 4 E4B on your Mac), Mistral, TensorX and OpenRouter. The remote ones only need your API key; then press *Use for Summaries*. If you already have Profiles, nothing changes.
- **Retry** of a failed Meeting keeps the Template it had, instead of the one shown in the menu (which goes back to the default at every stop): after a Provider error you get the same Summary you were waiting for.

## 1.8.0 (2026-10-21)

- **Screenshots** ([#4](https://github.com/mameli/Takku/issues/4)): while recording, ⌃⌥⌘S (or *Take a screenshot* in the menu) takes a picture of the screen you are looking at and marks the moment, like ⌃⌥⌘M. The pictures go into `Meetings/Screenshots/` in your vault and show up in the Transcript, under what was being said, and in the Summary, under the point they belong to (those that belong to no point are listed after it). They never leave your Mac: the model writing the Summary does not see them.

**Before you update**: the first ⌃⌥⌘S asks for the Screen Recording permission (new users get it as the last, optional step of the welcome window). macOS applies it once you reopen Takku, so give it after a meeting, not during one.

## 1.7.0 (2026-10-21)

- **Parakeet Ultra**: a new transcription model in *Settings → Transcription*. It is Parakeet v3 trained further by moondream: same 25 languages, same speed, fewer mistakes (on FLEURS, 24 languages, the error rate goes from 14.8% to 11.7% on average, and it is better than v3 in each of them). About 630 MB to download. Like v3, on short replies it can switch language.
- **Fewer made-up sentences with Parakeet**: on faint audio Parakeet, Ultra especially, can write sentences in a language nobody spoke (Slovak, German, Russian…). They are now dropped when they are clearly not in one of the Meeting languages ticked in *Settings → Transcription*: with only Italian ticked, English sentences are dropped too. Meetings already transcribed keep what they had.
- A word Parakeet could not recognise is written `[?]` in the Transcript, instead of an `<unk>` that Obsidian hid.
- Speakers are told apart better on short turns, with FluidAudio 0.17.7.
- WhisperKit 1.1.1: crash fixes and more robust model downloads.

## 1.6.0 (2026-10-21)

- **Open the notes in another editor**: *Settings → Obsidian Vault → Editor* chooses the app that opens the meeting notes and Transcripts, such as Zed or VS Code. Obsidian stays the default and the notes do not change. With another editor, *Recent meetings* opens the whole vault in it (or in the Finder, for editors that do not open folders). Turn on the editor's autosave: Takku reads your Personal notes from disk. More in the [README](https://github.com/mameli/Takku#using-another-editor).
- **Fix: your voice almost silent in the call while Takku records** ([#3](https://github.com/mameli/Takku/issues/3)). Takku's echo cancellation took over the built-in microphone: Teams and the other apps got almost nothing from it, until you quit Takku. Takku no longer uses it, and the others' voice the microphone picks up from the speakers is still removed from the Transcript.

## 1.5.1 (2026-10-20)

- **Better Summaries**, from the Summary log of 29 real meetings:
  - Actions are only what someone took on in the meeting, no longer every update of a stand-up, and with none there is no "No actions agreed" line.
  - Who does what comes from the Transcript only: names in the Personal notes or in the invitation, and voices Takku could not tell apart (*Others*), no longer get actions that are not theirs.
  - A variant listed in the Vocabulary always becomes its term in the Summary, and terms nobody said no longer turn up.
  - An email or a list of people pasted in the Personal notes is read as context, not as what was decided in the meeting.
  - Unnamed participants no longer appear as "Speaker N" in the bullets, and misheard figures or dates are left out instead of copied.
  - The default *Notes* Template groups a stand-up by project, writes its headings in the Summary language and leaves out *Next steps* when there are none. **Your `Notes.md` is not changed**: to get the new one, move it to the Trash and restart Takku.
- **Fix: *Use the calendar* turned itself off after an update.** When Takku found no access to the calendars it switched the setting off for good; now the switch only shows off until access is back, and the setting stays as you left it.

## 1.5.0 (2026-10-20)

- **Summary log**: Takku keeps a copy of every request it sends the model for a Summary, and of every reply, in `~/.takku/summary-log/`: one JSON file per Summary, Retry included, also when it fails. Use it to improve your Templates: write what was wrong in the `comment` field at the top of a file, then give a few files to a model you trust and ask what to change. Up to 5 MB, the oldest go first. It is on by default; turn it off, see how much it takes or delete it in *Settings → Recordings*. Takku never reads it, and *Report a problem…* never includes it.

## 1.4.1 (2026-10-20)

- **Fix: notes named after the wrong calendar event.** A meeting started a few minutes before the next call, or at the same time as other calls, could take the other event's name and participants. Takku still picks an event at the start, and while recording the menu now has *Calendar event*: every event in progress at the start, with its time, and *None*. Picking another one gives the note its name and participants; with *None* the Summary gives the title.
- Distribution lists invited to an event are no longer written in `participants`, like rooms and resources.

## 1.4.0 (2026-10-19)

- **Reasoning per Profile**: each Summary Profile can set how much the model reasons before answering: *Model default*, *Off*, *Low*, *Medium* or *High*. OpenRouter gets it in its own format and adapts it to each model; every other provider gets OpenAI's `reasoning_effort`, which not every model accepts.
- **Extra parameters**: a JSON field in the Profile for what a model needs beyond that, added to every request as written. For example `{"chat_template_kwargs": {"thinking": true}}` makes DeepSeek V4 reason on TensorX. The [README](README.md) has more examples; the provider's documentation says what to write.
- When the provider refuses a request, the error says what the Profile sets (reasoning, Extra parameters), and a long message from the provider is cut so that it stays readable in the notification and in the note.
- Replies from models that reason are read without their reasoning: Mistral's reasoning blocks and text between `<think>` tags no longer reach the Summary.
- **Faster Retry**: while the audio is there, a Retry no longer decodes the microphone audio or tells the Speakers apart again. On a 37-minute meeting the Summary request now starts after a fraction of a second instead of about 14. Thanks to [@tmnd1991](https://github.com/tmnd1991) ([#2](https://github.com/mameli/Takku/pull/2)).
- Processing logs every step with its timing, and *Report a problem…* includes them. They never contain the provider's address, only whether it is on this Mac or remote.
- **Hooks**: an example that writes the Summary with Copilot CLI, from your own subscription, for meetings recorded with *Transcript* only. See the [README](README.md).

## 1.3.2 (2026-10-15)

- The *buy me a coffee* link moves from the top of Settings to a grey note at the bottom.

## 1.3.1 (2026-10-15)

- **Buy me a coffee**: a link under the version in Settings, for anyone who wants to support Takku.

## 1.3.0 (2026-10-14)

### Removed: Steno support

Up to 1.2.0 Takku brought over what Steno had left on the Mac and read the notes Steno wrote. It no longer does either. If you never used Steno, nothing changes for you.

**Before you update**

- **Steno's settings, Recordings, models and API keys are no longer moved to Takku.** If Steno is still installed, open Takku 1.2.0 once before updating: it moves everything. Otherwise set Takku up again: choose the vault, add your Summary Profiles with their API keys, and download the transcription model. Steno's data folder, `~/Library/Application Support/Steno`, can then be deleted.
- **Notes written by Steno are no longer recognised.** A note or Transcript with `steno_id` in its frontmatter, or a summary between `%% steno:start %%` and `%% steno:end %%`, is no longer a Takku meeting: *Retry* cannot find it, it is missing from *Recent meetings → Show all in Obsidian…*, and the Hook is never run on it. Notes that Takku has rewritten at least once (after a Retry) already use `takku_id` and are fine.

  To convert the others, run this in your vault folder. It changes only the `steno_id:` lines and the two markers, in the files that have them. Back up the vault first, or commit it if it is a git repository.

  ```sh
  grep -rl --null --include='*.md' -e '^steno_id:' -e '^%% steno:' . | xargs -0 sed -i '' -e 's/^steno_id:/takku_id:/' -e 's/^%% steno:start %%$/%% takku:start %%/' -e 's/^%% steno:end %%$/%% takku:end %%/'
  ```

## 1.2.0 (2026-10-14)

- **Hook**: an executable at `~/.takku/hooks/after-processing` runs when each meeting is ready, and again after every successful Retry, with the paths of the meeting note and of the Transcript. Send meetings to Notion, Confluence, git or anywhere else. Guide and a ready-made Notion hook: [takku.app/hooks](https://takku.app/hooks).

## 1.1.0 (2026-10-13)

- **Templates and Vocabulary live in `~/.takku/`**, outside the vault and the same whatever the vault: `~/.takku/templates/` and `~/.takku/vocabulary.md`.
- Edit them from Settings with *Edit With*: a menu of the text editors on your Mac, your default one first. The Vocabulary row shows how many terms Takku read.
- Participants from the calendar are written readably: `ROSSI, MARIO` and `mario.rossi@…` become `Mario Rossi`.

**Before you update**

- Your Templates and Vocabulary are **not moved automatically**. Move them, or Takku uses its default Template and an empty Vocabulary:
  ```sh
  mkdir -p ~/.takku/templates
  mv <vault>/Meetings/_Templates/*.md ~/.takku/templates/
  mv <vault>/Meetings/_Vocabulary.md ~/.takku/vocabulary.md
  ```

## 1.0.1 (2026-10-11)

- The welcome window comes back in front after the microphone and system audio prompts.
- *Add a Profile in Settings…* opens Settings on the Summary Profiles, with a new Profile ready to fill in.
- **Call suggestions are off by default.** Turn on *Suggest recording when a call starts* in *Settings → General* to get them.

## 1.0.0 (2026-10-11)

- **Signed with an Apple Developer ID and notarized by Apple**: Takku opens like any other app, with no more *Open Anyway*.
- **Welcome window** at the first launch: permissions, vault, transcription model, summary and Open at login, step by step. *Set up Takku…* in the menu opens it again until a vault is chosen.

**Before you update**

- macOS treats the newly signed app as a new app once: it asks again for the microphone, the system audio and the calendars, and for your password to let Takku read the API keys you saved (choose *Always Allow*). Turn *Open at login* on again if you used it.

## 0.3.1 (2026-10-10)

- **Report a problem…** in the menu writes a report with Takku's version, your Mac, the models and the logs of the last 3 days, and opens a bug report on GitHub with those fields filled in. Nothing is sent by itself.

## 0.3.0 (2026-10-09)

- **Steno is now Takku**, from *taccuino*, the notebook in its icon. New app, bundle `app.takku.takku`, Homebrew cask `mameli/takku/takku` (`brew upgrade` replaces Steno with Takku). At the first launch Takku brought over Steno's settings, Profiles, Recordings, models and API keys.

**Before you update**

- The permissions (microphone, system audio, calendars, notifications) and *Open at login* must be granted again: macOS ties them to the app.

## 0.2.1 (2026-10-09)

- The ⭐ of a moment marked with ⌃⌥⌘M no longer shows up in the Summary.

## 0.2.0 (2026-10-09)

- **Calendar** (optional, *Settings → General*): a meeting started during an event gets a note named after it, with the invited people in `participants`, which help the Summary name the Speakers.
- **Speaker names**: write `speakers: - Speaker 1 = Mario Rossi` in the note's frontmatter and Retry: the Transcript shows *Mario Rossi (Speaker 1)* and the Summary uses the name.
- **Mark a moment** with ⌃⌥⌘M while recording: the passage gets a ⭐ in the Transcript and priority in the Summary.
- **Call suggestions**: a notification offers to start when a call app keeps the microphone, and to stop when it lets it go.
- **Silent Track warning**: the menu and a notification say when nothing is coming from the microphone or from the call.
- **Meeting languages**: 25 European languages in *Settings → Transcription*. One ticked is forced, several are detected.
- **Update check**: once a day Takku asks GitHub for the latest version and shows it in the menu. It can be turned off.
- **Recent meetings → Show all in Obsidian…**

## 0.1.5 (2026-10-09)

- The Summary calls you by your name instead of "Me". An unnamed participant appears as "Speaker N" only as who takes on an action.

## 0.1.4 (2026-10-07)

- **Speakers**: the Transcript tells the other participants apart (Speaker 1, Speaker 2…), and the Summary names them when the call makes clear who they are.
- The others' voice left in the microphone by echo cancellation no longer shows up in the Transcript as your words.

## 0.1.3 (2026-10-06)

- Every point of the Summary cites the time in the Transcript, and a Summary of a cut Transcript stops where the Transcript stops.

## 0.1.2 (2026-10-06)

- Notifications read the permission each time, so turning them on in System Settings works without restarting.

## 0.1.1 (2026-10-05)

- Install with Homebrew.
- Hardened Runtime: another process can no longer inject code into the app to record through its microphone and system audio permissions.

## 0.1.0 (2026-10-05)

First release.

- Records both sides of a call: the microphone, with echo cancellation, and the system audio.
- Transcribes on the Mac with Whisper (Large v3 Turbo, its full version, Small) or Parakeet v3, chosen and downloaded in Settings.
- Writes one note per meeting in the Obsidian vault, opened at the start for your personal notes, with the Summary at the top and the Transcript in its own file.
- Summary written by a provider you choose through any OpenAI-compatible API, with Profiles and keys in the Keychain, or no Summary at all.
- Templates for the Summary, a Vocabulary for names and jargon, Retry with another Template or Profile.
- Audio kept for 7 days, then deleted; Retry rebuilds the Summary from the Transcript in the vault.
- Global shortcut ⌃⌥⌘R, Open at login.
