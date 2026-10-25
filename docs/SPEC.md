# Takku: v1 specification

Terms in **bold** are defined in [CONTEXT.md](../CONTEXT.md). Architecture decisions are in [docs/adr](adr/).

## Goal

Record a **Meeting** on the Mac, produce its **Transcript** and **Summary** with **Providers** chosen by the user and write everything into the Obsidian **Vault**. Data stays local or in the EU by preference; where a Meeting goes is the user's choice ([ADR 0001](adr/0001-eu-by-preference.md)).

Personal use, one machine (M3 Pro, 18 GB, macOS 26). Meetings in Italian or English, one language per Meeting.

## Scope

**In v1**
- Menu bar app: start/stop, global shortcut, **Template** choice
- Capture in Call mode: **Tracks** Me (microphone) and Others (system audio)
- Local WhisperKit transcription in Segments during the call
- Language detected automatically or forced
- **Provider profiles** for the Summary, OpenAI-compatible adapter, keys in the Keychain, minimal Settings window
- **Meeting note** created at start and opened in Obsidian; **Managed section**; Transcript in a separate file
- Templates read from `~/.takku/templates/`, **Regeneration**, Retry
- **Vocabulary** in `~/.takku/vocabulary.md`: variants replaced in the Transcript, terms in the Summary prompt ([ADR 0005](adr/0005-vocabulary-without-llm-pass-or-engine-biasing.md))
- Recording kept for 7 days, **Processing** queue
- English user interface with Italian translation (string catalogs); English Vault format

**In v2**: see [v2](#v2) at the end. Speakers (*Speaker 1*, *Speaker 2*…) were added to v1 after its release ([ADR 0006](adr/0006-speakers-by-local-diarization.md)).

**Out of v2** (most likely first)
1. Remote transcription (local is enough: 12 minutes in 50 seconds on an M3 Pro); Profiles will then also get the transcription Role
2. Ready-made Provider presets
3. Automatic stop on silence at the end of the call (was phase 6): v2 suggests the stop when the call app releases the microphone instead
4. Vocabulary for the recognition engines (a prompt for Whisper; CTC boosting for Parakeet, tried and not usable in Italian). See ADR 0005.
5. An LLM pass that corrects the Transcript before the Summary (only if the variants and the Summary prompt prove not enough)

Dropped: Room capture mode (microphone only, for in-person meetings). Takku is for calls; an in-person meeting recorded elsewhere is imported instead (see [Imported audio](#imported-audio)).

## Main flow

1. **Start** (click or shortcut). Takku:
   - creates the Meeting identifier and the Recording folder and starts capturing the two Tracks (first, so no audio is lost);
   - creates the Meeting note `<Vault>/Meetings/2026-10-04 1430 - Meeting.md` (see [structure](#meeting-note));
   - opens it in Obsidian with `obsidian://open?path=<absolute path>`.
2. **During the call**: the user writes **Personal notes** in the note. Segments already closed are transcribed in the background. The Template can be changed from the menu bar; the Summary Profile is the one active at the start.
3. **Stop** (click or shortcut). The Meeting enters the Processing queue and another Meeting can start right away.
4. **Processing** (one at a time, in arrival order):
   1. completes the Transcript (the last Segments);
   2. reads the Meeting note again and extracts the Personal notes;
   3. generates Summary and title with the Summary Profile (with *Transcript* chosen instead of a Profile: no Summary, no Template, no title);
   4. renames the note with the title, if the user has not renamed or moved it (the Transcript is then named after the renamed note; an existing Transcript is never renamed);
   5. writes the Transcript file;
   6. rewrites the Managed section and Takku's frontmatter keys;
   7. notifies "Summary ready" (click → opens the note in Obsidian).
5. If a step fails: the Managed section shows `⚠️ Summary not generated: <reason>`. The Meeting stays in "Recent meetings" with **Retry**. No fallback to another Provider.

## Audio capture

- **Others**: global Core Audio process tap (`CATapDescription`, all processes: Takku plays no audio, so there is no need to exclude it) + aggregate device containing **only the tap**. An aggregate with the speakers as main device stops receiving audio when voice processing is active on the microphone, and call apps use it. It starts before the microphone. Requires `NSAudioCaptureUsageDescription`: the first time macOS shows the "System Audio Recording Only" prompt and the start waits for the answer.
- **Me**: `AVAudioEngine` on the default microphone, **without voice processing**. Up to 1.5.1 Takku turned it on for echo cancellation (`setVoiceProcessingEnabled(true)`), but on the built-in microphone it reconfigures the device and every other app, the call included, gets almost silence from it ([issue 3](https://github.com/mameli/Takku/issues/3): Teams' test call did not pick up the voice, QuickTime neither, with the input volume at maximum). The echo of the speakers is removed when the Transcript is built (see below). A microphone with more than two channels keeps channel 0. Requires `NSMicrophoneUsageDescription`. At the stop the engine is released, not only stopped. The engine stops whenever the audio configuration changes: opening the microphone of Bluetooth headsets (AirPods) switches them to call mode right after the start, and the default microphone can change during a Meeting (AirPods connected or removed). Takku first starts the same engine again (a new engine would switch the headset back to music mode and loop); if no audio arrives within 2 seconds, the microphone really changed and a new engine takes the new default one (at most 5 restarts a minute) and the hole, usually a second or two, is filled with silence so the Track stays aligned with Others. Any hole over half a second in a Track is filled the same way.
- Each Track is written in **5-minute Segments** (`me-000.m4a`, `others-000.m4a`, …), AAC mono 16 kHz. Reasons: a crash loses at most one Segment; closed Segments are transcribed during the call; files stay under remote Providers' upload limits.
- The two Tracks share the start clock: every Segment records its offset from the start of the Meeting. Each Track's Segment list (`me-segments.json`, `others-segments.json`) is updated whenever a Segment opens, so offsets survive a crash; at the stop it goes into `recording.json`, which is written even if a Track was interrupted.

**Stop on silence**: out of v1 by the user's choice (the Meeting is always stopped by hand, from the menu or with ⌃⌥⌘R).

## Transcription

- Each Track is transcribed separately. The Utterances of the two Tracks are sorted by start time and merged into paragraphs (rules below).
- A Segment that cannot be transcribed does not block the others: the Transcript is written with a gap and the error is reported.
- Whisper only gets the **speech ranges** of each Segment: half-second windows with RMS above 0.004, pauses under 2 seconds absorbed, a quarter of a second of margin on each side. On silence, echo residue and distant voices Whisper makes up sentences ("Grazie.", dozens of times in the phase 1 test). Annotations such as `[BLANK_AUDIO]` or sentences in parentheses are dropped anyway. A speech range with at most 3 seconds of sound (pauses and margins excluded) whose whole text is a stock subtitle sentence ("Grazie.", "Thank you.", "Sottotitoli creati dalla comunità Amara.org"…) is dropped too: it is Whisper's reaction to a short noise such as a notification sound. A real isolated "Grazie." from the others is lost with it. With Parakeet, a sentence of at least 2 words (hesitations such as "uh" and "um" not counted) is dropped when macOS's language recogniser rules out the Meeting languages ticked in Settings (all of them together below 1%, the most likely one not among them): on faint audio Parakeet writes made-up sentences in Slovak, German, Swedish or Russian. On 38 real Meetings in Italian and English (7 hours of speech) this dropped 37 Parakeet Ultra sentences, 31 of them in one Meeting where the Me Track was only residue too loud for the level filter below (loudest Me sentence at -29 dBFS), and 4 Parakeet v3 ones; about 2 were real short replies ("Vai Lucas?"). With only Italian ticked, an English sentence is dropped too. It is applied when the Segment is transcribed, so it reaches the cache: older Recordings keep what they had. Echo leaked into the microphone (speakers without headphones) is removed when the Transcript is built: a run of Me Utterances (pauses under 2 seconds) of at least 3 words, 80% of which appear in the same order in what Others say within 5 seconds, is dropped. In Recordings made up to 1.5.1, with echo cancellation, what it left of the others' voice is too garbled for that: it peaks around -40 dBFS, against -10 to -25 for the user's own voice, and recognition turns it into random words in any language ("The five.", "Oh yeah"). Me Utterances whose peak level (RMS of the loudest 100 ms) is more than 25 dB below the loudest Me Utterance of the Meeting are dropped too; the reference is the loudest one because in a Meeting where the user barely speaks most Me Utterances are residue. On 13 real Meetings this removed 205 of 249 Me Utterances in the worst one and kept the faintest real replies by over 10 dB. Both are applied when the Transcript is built, not to the cache, so Retry cleans older Recordings too; only the peak level of each Me Utterance is cached, so a Retry does not decode the audio again.
- **Speakers**: the Others Track is diarized locally after its Segments are transcribed, with FluidAudio's offline pipeline (pyannote community-1, models of about 22 MB downloaded on first use to `Takku/Models/fluidaudio/speaker-diarization`). The Segments are joined in one temporary file, each at its start, so a voice keeps its number across Segments. Each Others Utterance takes the voice whose turns cover most of it; one that overlaps none (a short "ok" the diarizer did not count as speech) takes the voice of a turn within 2 seconds, otherwise it stays *Others*. Voices are numbered *Speaker 1*, *Speaker 2*… in the order they first speak in the Transcript. The Speaker turns are cached in `speakers.json` in the Recording folder, keyed by name, start and size of every Others Segment and by a diarizer version: a Retry diarizes again only if the Others Segments changed or the version was bumped (new diarizer or model). Turns missing an unreadable Segment are cached too: the key changes if that file does. The turns are assigned to the Utterances when the Transcript is built, not in the cache. If diarization fails the Transcript keeps *Others* and the error is a warning. The Me Track is not diarized: it is one person.
- A Transcript paragraph joins consecutive Utterances of the same Track and Speaker, but breaks after a pause longer than 30 seconds or when an Utterance starts more than 60 seconds after the paragraph's start: a new timestamp about every minute (a Whisper Utterance is at most 30 seconds long).
- The **Vocabulary** variants are replaced with the term in the paragraph text, once the Utterances are merged (so a variant that crosses two Utterances of the same paragraph is found), when the Transcript is built, not in the cache: like the echo removal, a Retry with the audio uses the Vocabulary of that moment. A variant matches as a whole word (letters and digits on either side stop a match, an apostrophe or punctuation does not: `l'abtakku` → `l'Takku`), ignoring case; the longest variant wins; the replacement is the term as written in the Vocabulary. It also applies with *Transcript* chosen as Summary Profile. A Regeneration does not touch the text already in the Vault.
- The result of each Segment (language and Utterances; for Me Segments also the peak level of each Utterance, with a levels version) is saved next to the audio (`me-000.m4a.json`), so a new Processing does not transcribe again what is done. Levels missing, of another levels version (bumped when the measure or the Utterance windowing changes) or not matching the Utterances are measured again on the audio and the cache rewritten, without transcribing again.
- **Models**: Large v3 Turbo (`openai_whisper-large-v3-v20240930_turbo_632MB`, 646 MB, default), Large v3 Turbo full (`…_turbo`, 1.6 GB) Small (`openai_whisper-small_216MB`, 217 MB), NVIDIA Parakeet TDT 0.6B v3 (through FluidAudio, about 490 MB) and Parakeet Ultra (`parakeet-ultra`, moondream's further training of v3: same languages and speed, lower error rate; about 630 MB, through FluidAudio), all multilingual. Parakeet (v3 and Ultra) cannot be held to a language: it picks one per stretch of speech and on short, unclear replies can switch (e.g. to English or Portuguese); the Meeting language is read from its text with macOS's language recogniser. Its tokens are joined into sentences at final punctuation or after a 1.5 s pause. A word it could not recognise, `<unk>` (4 times in 7 hours with Ultra, never with v3), is written `[?]`: Obsidian would hide `<unk>` as an HTML tag. Settings → *Transcription* downloads them (with a percentage, then "Preparing…" while Parakeet is compiled), chooses the one in use and deletes the others; the model is changed rarely, so the menu bar does not offer it. A Meeting keeps the model it started with; Retry uses the one in use. The per-Segment cache records the model: Segments transcribed by another model are transcribed again.
- **Local**: WhisperKit; the model in use is downloaded on first use to `~/Library/Application Support/Takku/Models` and prepared while the first Meeting is in progress. The menu shows "Downloading transcription model… N%", then "Preparing transcription model, first time only" (macOS compiles it for the Neural Engine: a few minutes, once) or, on later launches, "Loading transcription model…". A marker file written after the download makes an interrupted download resume instead of loading a partial model.
- **Language**: detected among the Meeting languages ticked in Settings, or forced when only one is ticked (v1: `auto` or forced `it`/`en`, see [Meeting languages](#meeting-languages)). Detection runs on up to 30 seconds of speech only (the voice ranges, no silence) of the first Segment that has any, from either Track, picking only among those languages, and holds for the whole Meeting. It is locked only when there are at least 10 seconds of speech: on a short "ok" Whisper can pick the wrong language and then *translate* instead of transcribing. With less speech the detected language is provisional: it applies to that Segment only, detection is tried again on the next one, and at the end of Processing the Segments transcribed with a provisional language different from the locked one are transcribed again. If the language is never locked (very little speech in the whole Meeting) the provisional results stay. Detecting on the first 30 seconds of audio is not enough: in the real phase 1 test the Me Track started with 80 seconds of near silence and Whisper classified it as Swedish. The language used is saved in every Segment's cache; if a different language is forced later, the Segment is transcribed again.
- **Remote** (after v1): `POST {baseURL}/audio/transcriptions` (multipart, one Segment per request) through the OpenAI-compatible adapter. Only at the stop: during the call the audio never leaves the Mac.

File `<Vault>/Meetings/Transcripts/2026-10-04 1430 - <Title> (transcript).md` (a copy without frontmatter stays in `transcript.md` in the Recording folder while the audio is there). A new Processing of the same Meeting overwrites the existing file, found through `takku_id`:

```markdown
---
takku_id: 6F1C…
meeting: "[[2026-10-04 1430 - Title]]"
language: it
---
**[00:00] Speaker 1:** Buongiorno a tutti, partiamo dal…

**[00:42] Me:** Sì, sul primo punto…

**[00:47] Speaker 2:** Ok.
```

Transcripts written before Speakers existed have *Others* instead and still read back.

## Meeting note

```markdown
---
takku_id: 6F1C…
date: 2026-10-04T14:30
duration: 47m
template: Notes
language: it
summary_provider: Mistral EU
transcript: "[[2026-10-04 1430 - Title (transcript)]]"
tags: [meeting]
---
%% takku:start %%
⏺ Recording in progress: the summary will appear here after you stop.   ← then the Summary
%% takku:end %%

## Personal notes

```

Rules:
- Takku rewrites **only** the text between `%% takku:start %%` and `%% takku:end %%` and **its own** frontmatter keys (`duration`, `language`, `summary_provider`, `template`, `transcript`). Keys added by the user stay. `date` and `tags` are written only at creation: from then on they belong to the user. `takku_id` is restored at every update if the user deleted it, otherwise the note could not be found again.
- `takku_id` counts only in the frontmatter (the same text in the body does not identify the note). Managed section markers inside code blocks do not count. Notes with Windows line endings or a BOM are read correctly and rewritten with `\n` line endings.
- Takku updates the note in place (it does not replace the file), checking that it did not change between read and write: if Obsidian saved it meanwhile, Takku reads it again and reapplies the change.
- If Processing fails, the Managed section shows `⚠️ <reason>` instead of staying on "Recording in progress".
- Between creation and the end of Processing Takku does not write to the note (no intermediate "Processing" state): progress shows in the menu bar.
- If the Vault is not reachable at start (volume not mounted, folder moved) the Meeting is recorded anyway and the note is created at the end of Processing. The same happens if the user deletes the note during the Meeting.
- **Personal notes** = the whole body outside the Managed section, without the `## Personal notes` heading. If empty, the Summary relies on the Transcript only.
- If the markers were deleted, Takku recreates them at the top of the body, without deleting anything.
- The note is found through `takku_id`: first at the known path, otherwise by searching the Meetings folder. If the user renamed or moved it, Takku does not rename it.
- When a name already exists a ` (2)` suffix is added.
- Without the calendar, `participants` is not written in v1.
- Takku writes only once Processing is over, i.e. minutes after the stop, to avoid conflicts with edits still open in Obsidian.

## Template

- Folder `~/.takku/templates/`, global like the Vocabulary: the same whatever the Vault. The default Template is `Notes.md`, Granola style: topics in the order they were discussed, each with a `###` heading and bullets with sub-bullets (reasons, people, figures, links), one topic per project in a stand-up, who only when the Transcript makes it clear, then `### Next steps` with `- [ ] What to do (Who)` and the deadline below, only for actions taken on in the Meeting (not work in progress reported, not waiting), left out when there are none, headings in the Summary language. No opening summary and no fixed sections. Takku creates it at app launch, if the folder is empty or if the default Template no longer exists (then the default goes back to Notes).
- Format: frontmatter with `name` and `summary_language` (any language code such as `it`, `en`, `fr`, `de`; `auto` or missing = the Meeting's language). The body, i.e. free-form instructions and heading structure, is passed to the model as it is.
- The Template is chosen at start (default from Settings) and can change until the stop.
- In Settings, Templates section: list, default Template, "New Template" (name → file created from Notes; *Create* does not open it), "Edit With", "Delete" (asks for confirmation, then moves the file to the Trash with no further message: the row disappearing is enough; if it was the default, Notes becomes the default again; Notes itself cannot be deleted). A Meeting whose Template is gone uses Notes, as the user edited it; only without it the built-in text. *Edit With* is a menu of the apps that edit Markdown or plain text (the Editor role in their document types; viewers such as browsers, Instruments, Pages and Numbers are left out), with their icon, the system's default for Markdown first and marked *(default)*, the others in alphabetical order; read from Launch Services every time Settings opens. The files are outside the Vault, so Obsidian is not offered. Takku has no editor. The list is read again when Takku comes back to the front, so Templates added or renamed in Finder show up.

## Vocabulary

The names, acronyms and technical words that recognition gets wrong, in the file `~/.takku/vocabulary.md`, written in the user's editor like the Templates. It is global (it applies to every Meeting, whatever the Vault) and is read at every Processing: a change counts from the next Meeting, or from a Retry with the audio. If the file is missing or empty everything works as before. It also applies without a Vault, to the Transcript left in the Recording folder. Why it works this way and not through the engines or an LLM pass: [ADR 0005](adr/0005-vocabulary-without-llm-pass-or-engine-biasing.md).

One entry per line, as a Markdown list item:

```markdown
- Takku = abtakku, takku | our app for recording meetings
- Scaleway = scale uai
- Mameli
```

- `Term` is the correct form. After `=`, comma-separated, the variants usually heard instead (optional). After `|` a short description (optional). Extra spaces are ignored.
- Lines that do not start with `- ` (headings, notes, blank lines) are ignored, so the file can hold free text.
- Two entries with the same term: the first one counts. The same variant in two entries: the first one counts. A variant equal to its own term is ignored.
- The variants are used for the substitution in the Transcript ([Transcription](#transcription)). The terms, variants and descriptions go to the Summary prompt ([Summary](#summary)). The recognition engines get nothing.

## Summary

- `POST {baseURL}/chat/completions` with:
  - **fixed system prompt** (in English): write the summary in the language stated explicitly ("Write the summary in Italian", whatever language the Template is written in), follow the Template's structure and instructions, do not invent, end every bullet with the time of the Transcript passage it comes from and leave out what has none, summarise a Transcript cut mid-sentence only up to where it stops (also in partial requests), attribute to Me/Others, Me is the user's macOS full name (`NSFullUserName`) and is written by name, never as "Me", actions as a checklist in the Template's format (otherwise `- [ ] who: what (when)`), only for what someone took on in the Meeting, with who only when the Transcript makes it clear (a name in the Personal notes or in the invitation is not enough) and no line when there are none, give priority to the topics of the Personal notes, which may hold pasted material (an email, a list of people) that is context and not what was said, give *Others* a name only where the Transcript says who is speaking, write a bullet without a subject rather than with "Speaker N", leave out passages that make no sense instead of copying them;
  - **user message**: Template, Personal notes, Transcript.
  - **Vocabulary**, if there is one: a block in the system prompt in every request (single, partial, group, merge and title) with each term, its variants ("may be written as …") and its description. The prompt says the Transcript comes from automatic speech recognition and may spell names and technical terms wrong; a word written as a listed variant is always the term; for other words the model uses the Vocabulary and the context to write them right, and corrects only when it is sure, otherwise it leaves the text as it is; it does not bring in a term nobody said. It does not turn the Transcript into something else: the existing rule *do not invent* still holds.
- **Cited times**: Takku removes them from the final Summary (`[12:34]`, `[03:10] [07:45]`, `([1:02:45])`, `[04:00-06:30]`), so they tie every point to the Transcript without being shown; the partial summaries keep them for the merge. Checkboxes, wikilinks and Markdown links stay.
- **Summary language**: the Template's `summary_language` (any language), otherwise the Meeting's detected language, otherwise (no speech, or detection failed) Italian.
- **Title**: a second short call on the Summary ("at most 6 words, no date", in the Summary language), cleaned of headings, "Title:" prefixes, quotes, bold and final punctuation. If no title comes back the note keeps its provisional name: it is not an error.
- **Managed section**: the Summary followed by `Full transcript: [[…]]`. With *Transcript* chosen as Summary Profile it holds only the `Full transcript: [[…]]` link, with no warning, and the note keeps its provisional name. If the Summary fails (Provider error, Meeting without speech) it shows `⚠️ Summary not generated: <reason>` and the Transcript link, which stays usable. Managed section markers in the model's reply are removed.
- **Token estimate**: about 3 characters per token, with 4,096 tokens reserved for the reply; a block never splits a Transcript paragraph.
- **Long Meetings**: every Summary Profile has a *max context* field. If Transcript + notes + Template exceed it, the Transcript is split into blocks, every block is summarised and the partial summaries are merged with the Template (in groups, if even the merge does not fit).
- **Regeneration**: what Retry does once the audio is deleted. Reads the current Transcript and Personal notes again from the Vault and rewrites only the Managed section; a note still with its provisional name gets the title. To summarise again with another Template or Profile, choose them in the menu and Retry (a failed Meeting keeps its Template).

## Profiles and settings

**Profile** (v1: Summary only): name, base URL, API key (in the Keychain, optional for local servers), model, max context, reasoning, Extra parameters. **Ready-made Profiles**: at the first launch without Profiles, Settings gets five, none active: *Takku Credit* (below), *Ollama* (`http://localhost:11434/v1`, `hf.co/ggml-org/gemma-4-E4B-it-GGUF:Q4_0`, 32,000 tokens), *Mistral* (`https://api.mistral.ai/v1`, `zai-glm-5-3-flash`), *TensorX* (`https://api.tensorx.ai/v1`, `deepseek/deepseek-v4.1-flash-1017`, reasoning Low) and *OpenRouter* (`https://openrouter.ai/api/v1`, `anthropic/claude-haiku-5.5`), the remote ones with 128,000 tokens and waiting for their API key. Added once (`readyMadeProfilesAdded`): deleted, they do not come back, and those who already have Profiles do not get them. **Takku Credit**: prepaid credit sold at takku.app, served by `https://api.takku.app/v1` (an OpenAI-compatible gateway with one model of its own, `takku-summary`, 128,000 tokens). The Profile is recognised by that host, whatever its name: its editor shows no address, model, context, reasoning or Extra parameters, only a short note on where the text goes, the key and the **credit** (`GET /v1/balance`, read when the editor opens, after the key is saved, when Takku comes back to the front and with *Refresh*). Without a key, *Buy credit…* opens takku.app/credit; with one, *Add credit…* opens the recommended pack's link (10 €) and its menu lists every pack the gateway offers (5, 10 · Recommended, 20 €); each link carries the key's public id, so the payment tops up that key whatever email is typed at checkout. Those who have no Takku Credit Profile (Profiles from before, or deleted) get an *Add Takku Credit* button next to *Add Profile*; deleting the Profile asks first, since its key holds the credit. A 402 from that host means the credit is used up: the Summary fails with "Your Takku Credit is used up. Add credit in Settings → Summary Profiles, then Retry the Meeting." Other examples: "Local llama.cpp" (`http://localhost:8080/v1`), "Mistral EU" (`https://api.mistral.ai/v1`). Transcription is always local (WhisperKit). A Profile outside the EU (e.g. OpenRouter) is allowed only for development with test recordings: Takku does not prevent it, the choice stays with the user (exception recorded in ADR 0001). The Profile is fixed when the Meeting starts; if it is deleted before the Summary (its key goes with it), the Summary fails saying so, and Retry with another Profile fixes it. A new Profile is not made active by itself, and neither is another one when the Profile in use is deleted: the menu goes to *Transcript* until the user chooses one. The URL must be `https://`; `http://` is allowed only for servers on this Mac (`localhost`, `127.0.0.1`, `::1`): to any other machine, even on the local network, key and Transcript would travel readable.

**Reasoning** (ADR 0009): *Model default* (nothing sent), *Off*, *Low*, *Medium*, *High*; sent as `reasoning.effort` to OpenRouter (recognised by its host) and as `reasoning_effort` (`none`, `low`, `medium`, `high`) to every other Provider. Takku keeps no list of what each model accepts. **Extra parameters**: a JSON object the user writes in the Profile, added to every request of the Profile (Summary, blocks and merge, title, *Test connection*); each top-level key replaces what Takku would send for it, the reasoning included, with no deep merge. The editor saves them only when they are a JSON object without `model` or `messages` (the field shows why otherwise, and *Test connection* is disabled); the field has no smart quotes. Request body only, no HTTP headers. A request refused with 400 or 422 from a Profile with reasoning or Extra parameters gives the Provider's message followed by what the Profile sent ("The Profile sets Reasoning: High and Extra parameters."; the level is left out when the Extra parameters replaced it), never the Profile's name or the parameters, since the message goes to the log too. The Provider's message is cut at 300 characters with "…" (some put whole JSON bodies in it), so what the Profile sets stays readable in the notification and the note. No automatic retry without them. The reply is read with the reasoning left out: `reasoning_content` is ignored, Mistral's list of chunks keeps the `text` ones, and anything up to the last `</think>` or `</thinking>`, whichever comes later, is dropped.

**Settings** (UserDefaults; secrets in the Keychain). In the v1 Settings window:
- Open at login (a login item registered with macOS, also visible in System Settings → General → Login Items)
- Vault path
- Templates and default Template
- Summary Profiles and active Profile (with "Test connection")
- Vocabulary: the number of terms read from the file ("No terms yet" if it is missing or has none) with the first four below, in the file's order, "and N more" after them, so a line written in the wrong format shows by its term missing; the path and an example entry in the footer; "Edit Vocabulary With", the same editor menu as the Templates (creates the file with an example if it is missing, then opens it with the chosen app)
- Transcription: models (Download, Use, Delete; the one in use cannot be deleted)
- Recordings: days the audio is kept (default 7), space used, "Show in Finder", "Delete audio" (all concluded Meetings, with confirmation). A shorter retention applies at the next cleanup, not on the spot. Below it the **Summary log**: "Keep a Summary log" (on by default), space used, "Show in Finder", "Delete log" (with confirmation).

- Meeting languages (see [Meeting languages](#meeting-languages)), in the *Transcription* section

The global shortcut is fixed: ⌃⌥⌘R. If another app already uses it, the menu says so.

The folders are fixed: `Meetings/`, `Meetings/Transcripts/`, `Meetings/Screenshots/`, `Meetings/_Templates/`; the Vocabulary is the fixed file `Meetings/_Vocabulary.md`. The Italian format of earlier development versions is not supported: those notes and Recordings were deleted.

## Menu bar

- **Idle**: Start meeting (shortcut) · Import audio… · Template ▸ (hidden when the Summary Profile is *Transcript*) · Summary Profile ▸ (*Transcript* or a Profile) · Recent meetings ▸ (Open note · Retry, then Show all in Obsidian…) · "Takku x.y.z is available…" when there is one · Set up Takku… (only without a Vault) · Report a problem… · Settings… · Quit
- **Recording**: only a red dot in the bar (a star for a second after a Mark, a camera after a Screenshot); in the menu "Recording · duration" · the silent Track warnings · Stop · Mark this moment (⌃⌥⌘M) · Take a screenshot (⌃⌥⌘S) · "Marked moments: N" · "Screenshots: N" · Template ▸ · Settings…
- **Processing**: hourglass in the bar; in the menu "Processing… (N more queued)"

The interface is in English in the code and translated to Italian in `Takku/Localizable.xcstrings` and `Takku/InfoPlist.xcstrings`: macOS picks the language of the system. Error messages from `TakkuCore` are looked up in the app's catalog too. The structure Takku writes into the Vault (headings, markers, keys, labels, status lines such as "Summary not generated:") is always in English; the error detail after it follows the app language, like the menu.

## State and retention

- `~/Library/Application Support/Takku/Recordings/<takku_id>/`: audio Segments, per-Segment transcription cache (model, language, whether it was reliable, Utterances, Me levels and their version), `speakers.json` (Others Segments diarized, Speaker turns, diarizer version), `recording.json` (start, end, Segments) and `processing.json` (status: recording, queued, processing, regenerating, completed, failed with reason; Template; Profile fixed at start; note path).
- Persistent Processing queue, one Meeting at a time: at app restart queued or in-progress Processing resumes, oldest first. A Recording interrupted by a crash is rebuilt from the Segment lists and queued: only the Segment open at the crash is lost (an unclosed AAC file is unreadable).
- An unreadable Segment is a warning ("Incomplete transcript"), not a failure: the Summary is generated with what there is.
- At app launch and every day: deletion of the audio (and transcription caches, `speakers.json` and the `screenshots/` folder, already copied into the Vault) of Meetings older than 7 days that are processed or failed, never of those recording, queued, processing or regenerating. `recording.json` and `processing.json` stay: the Meeting stays among the recent ones and Retry makes the Summary again from the Transcript in the Vault. About 20 MB of audio per hour of Meeting (AAC mono 16 kHz, about 180 KB per minute for each Track with sound).
- **Summary log** ([ADR 0010](adr/0010-summary-log.md)): `~/.takku/summary-log/<date> <time> - <Template> - <model>.json`, one per Summary (Retry and Regeneration included, failed ones too), written when the Summary ends. `about`: an empty `comment` the user fills in by editing the file, `takku_id`, note name after the rename, Meeting start, Template, Profile name, model, *on this Mac* or *remote* (never the address), error. `calls`: every request in order (`single`, or `partial`/`group`/`merge`, then `title`) with the request and reply bodies as they went, HTTP status and seconds. Past 5 MB the oldest entries are deleted, the newest always stays. Separate from the audio's retention; never read by Takku, never in *Report a problem…*.
- **Notifications**: "Summary ready" (click → note in Obsidian) or "Processing failed" with the reason.
- **Global shortcut** ⌃⌥⌘R: starts or stops the Meeting from any app.
- **Recent meetings** (the last 5): Open note · Retry. A concluded Meeting whose note was deleted from the Vault is not listed (its Recording stays until the audio expires); the name shown is the note's current one. The list is read again whenever the menu opens. Retry uses the Summary Profile chosen in the menu at that moment and, for a completed Meeting, the Template chosen there too; both become the Meeting's. A failed Meeting keeps its own Template: the menu went back to the default one at the stop, and a Retry after a Provider error should redo the same Summary. While the audio is there it redoes the whole Processing (Segments already transcribed come from the cache); without it, it is a Regeneration from the Transcript in the Vault. Retry appears only for concluded Meetings (completed or failed), never for one recording or queued. A Regeneration interrupted by a restart is not repeated: the Meeting goes back to completed with the previous Summary.
- Without a configured Vault Processing stops at the Transcript and the notification says "Transcript ready", not "Summary ready".

## Project structure

- **Xcode app** `Takku` (SwiftUI, `MenuBarExtra`, macOS 15 target, Personal Team signing): audio capture, WhisperKit, notifications, shortcut, Keychain, UI.
- **Local Swift package** `TakkuCore`, testable with `swift test` and without AppKit or AVFoundation: Segments → Transcript merging, reading and writing the Meeting note (Managed section, frontmatter, lookup by `takku_id`), Template parsing, prompt building and chunking, OpenAI-compatible client, Profile URL check, queue states, retention rules.

Tests: Swift Testing on `TakkuCore`, TDD. Capture and transcription are verified by hand with test Recordings saved as fixtures. Automated runs of the app (DEBUG builds) refuse to start unless isolated with `-vaultPath`, `-testSummaryBaseURL` and `-dataDirectory`.

## Phases

Every phase closes with a concrete check.

| # | Phase | Done when |
|---|---|---|
| 0 | Xcode project + `TakkuCore`, signing, Info.plist, `MenuBarExtra` with Start/Stop | The app starts in the menu bar and asks for permissions only once |
| 1 | **Capture** of the two Tracks in Segments, echo cancellation | A 12-minute Meet/Teams call produces 3+3 audible Segments, with Me free of the others' echo |
| 2 | **Local transcription** in Segments + Me/Others merge | The test call's Transcript file is readable, ordered and attributed |
| 3 | **Vault**: Meeting note, Managed section, frontmatter, `takku_id` (renaming moved to phase 4, with the title) | Tests green; the note appears in Obsidian at start and Personal notes stay intact after Processing |
| 4 | **Summary**: Settings window, Profiles, Keychain, OpenAI-compatible client, Templates, chunking, title and rename | Correct Summary of the test call with a remote Provider (in development OpenRouter, test recordings only). Still to try when the user sets them up: a local server (llama.cpp) and an EU Provider |
| 5 | **Full flow**: persistent queue, Regeneration, Retry, notifications, shortcut, retention | Two consecutive Meetings processed in the queue; Retry after stopping the local server |
| ~~6~~ | ~~Stop on silence~~ | Dropped: the user prefers to always stop by hand |

## Known risks

- **Echo without echo cancellation**: on the speakers the others' voice reaches the Me Track clean and loud, so only `removingEcho` (words in the same order in Others) removes it. The 25 dB residue rule and the RMS 0.004 of the speech ranges were measured with voice processing on, which also has gain control and noise suppression: on the raw built-in microphone check that quiet replies stay and that keyboard noise does not turn into made-up sentences. If too much echo stays: offline echo cancellation with the Others Track as reference (e.g. WebRTC AEC3), never voice processing during the call.
- **Local server context**: llama.cpp (`llama-server -c`), Ollama (`OLLAMA_CONTEXT_LENGTH`) and LM Studio have a small default context that cannot be changed per request through the OpenAI-compatible endpoint: it must be set when the server starts, consistent with the Profile's *max context* (minimum 8,192 tokens, Takku does not go below).
- **Truncated replies**: if the model stops at the length limit (`finish_reason: length`) the Summary counts as failed, not saved halfway. Very long Meetings merge partial summaries in groups until the final merge fits in the context.
- **Gaps in the audio**: a Segment's offset is computed from the frames written since the start of the Track. If a source drops buffers (device change) the later offsets of that Track drift relative to the other. Phase 2: in the real 12-minute call the two Tracks end less than 10 ms apart, no visible drift in the Transcript. If it shows up (e.g. headphones plugged in mid-call), realign every Segment with the host time of its first buffer.
- **Words cut between Segments**: the 5-minute boundary can split a word. Phase 2: with 5-second Segments a sentence across two Segments comes back together correctly; in the real call no words were lost at the boundaries. If it matters, add a short overlap between Segments.
- **Whisper non-deterministic on degraded audio**: with temperature fallback, the same range can give different texts in two Processings. In the phase 2 test (voice picked up by a phone in another room, through Meet and played by the speakers) the first sentence was lost in one run out of three. Disabling the fallback makes the result stable but worse; Whisper's "no speech" threshold is disabled because it dropped exactly these ranges. To reassess if it happens with normal call audio.
- **Renaming with the note open in Obsidian**: Obsidian does not follow the rename: it closes the note and shows the previous one. Takku reads in `.obsidian/workspace.json` which note Obsidian shows. If, before the rename, it was the Meeting note, Takku waits 3 seconds for Obsidian to notice the rename and then, if Obsidian does not show the renamed note, opens it and checks again (up to 3 times). If Obsidian is not the frontmost app it waits (up to an hour) for the user to come back to it instead of bringing it forward. A note Takku opens meanwhile (a new Meeting, a notification) cancels the wait. If the user was looking at another note, nothing happens. Correctness over speed: the note may appear a few seconds after the notification.
- **Renaming with the note open in Zed**: Zed follows the rename, but a write that arrives within about a second of it, before or after, is lost: the tab keeps showing the note without the Summary, even though the file has it (tried by hand: rename and write, write and rename, both lost; rename, 1 second, write, shown). So a write to a note just renamed waits 1.5 seconds (`Vault.settleAfterRename`): the Summary at the end of Processing, the participants of another calendar event.
- **Short Vocabulary terms and variants**: a variant is replaced everywhere it appears as a whole word, so a variant that is also a real word ("acne" for "Acme") would corrupt correct text; whoever writes the Vocabulary chooses the variants. Short terms that sound like common words ("Takku" next to "meno", "sono") are one more reason there is no engine biasing: the Summary prompt resolves them from context instead.
- **Whisper model download**: WhisperKit downloads the weights from Hugging Face. It is not Meeting data and does not affect ADR 0001, but it needs the network on first launch.

## v2

What comes after v1, in implementation order. Every item keeps ADR 0001: nothing about a Meeting leaves the Mac except towards the Summary Provider and the user's own Hook.

### Silent Track warning

A Track that records nothing is noticed during the Meeting, not after it.

- While recording, each Track remembers when it last received sound: a buffer whose peak is above -80 dBFS. The silence Takku writes itself to fill holes does not count. A real microphone never goes that low (its noise floor is higher); a Track that stays below it is digital silence: permission revoked, a device that delivers nothing, a broken tap.
- **Menu**: while a Track has had no sound for 2 minutes, a line under the timer says so: "⚠️ No sound from the microphone for N min" or "⚠️ No sound from the system audio for N min". It disappears as soon as sound comes back. During a quiet stretch of a call (the others say nothing) the line for the system audio can appear: it is information, not an error.
- **Notification**: once per Track per Meeting, only when the Track has had no sound **since the start** for 2 minutes, the case where the Meeting would be lost: "No sound from the system audio" · "Takku has recorded nothing from the call for 2 minutes. Check System Settings → Privacy & Security → Screen & System Audio Recording." (for the microphone: "… → Microphone").
- Nothing is written in the note; the Recording goes on.

### Meeting languages

- Settings → *Transcription* → *Meeting languages*: a list of languages to tick. Detection picks only among those ticked; with a single one ticked, it is forced and there is no detection. At least one stays ticked. Default: Italian and English (what v1 did).
- The languages offered are those both engines handle: the 25 of Parakeet v3 (Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish, Ukrainian). Whisper detects among them through its language probabilities, Parakeet's text through macOS's language recogniser constrained to them.
- The Settings list has Italian and English first, then the others by name. When nothing can be detected the fallback is the first ticked language in that order, as Italian was in v1.
- The `language` key of v1 (`defaults write … language it`) is migrated once: `it` or `en` becomes that single language ticked, `auto` Italian and English.
- The hallucination filter and everything else that depends on the language stay as they are; the stock sentences list may need new entries for new languages.

### Calendar

- Settings → *General* → *Use the calendar* (off by default). Turning it on asks macOS for full access to the calendars (`NSCalendarsFullAccessUsageDescription`); if it is denied the switch goes back off and a line explains how to allow it in System Settings.
- At the start Takku looks, among the events of all calendars, for the one in progress: not all-day, not cancelled, not declined by the user, starting at most 10 minutes from now and not yet ended. Among several, the one that has attendees, then the one whose start is closest to now. Reading the calendar never delays the start of the recording.
- **Another event**: the time alone cannot tell back-to-back calls apart (a call started at 12:28 that runs past 12:30, or the next one joined early) nor two calls at the same time. So while recording, the menu has *Calendar event* with every event that fit at the start, the chosen one ticked (`Title · 12:00–12:30`), and *None*. Picking another one renames the note after the new event, if the note still has the name Takku gave it (the previous event's, or the provisional one), and 1.5 seconds later replaces `participants` with its attendees (see *Renaming with the note open in Zed*); with *None* the note goes back to the provisional name and gets a generated title at the end of Processing. A note the user renamed or moved keeps its name. Obsidian is shown the renamed note if it was showing it. Only while recording, and only if the note was created at the start.
- With an event:
  - the Meeting note is named after it: `2026-10-04 1430 - Weekly sync.md`. Not having the provisional name, it is not renamed with the generated title (the title call is skipped);
  - its frontmatter gets `participants`, the attendees except the user and except rooms, resources and groups (distribution lists), by name or, without one, by email, made readable (`ROSSI, MARIO`, `Rossi, Mario` and `mario.rossi` or `mario.rossi@…` become `Mario Rossi`, `m.rossi@…` becomes `M. Rossi`; a name in mixed case stays as it is, an address without two words in it stays whole), written only at creation like `date` and `tags` (the user can correct it):
    ```yaml
    participants:
      - "Mario Rossi"
      - "Anna Bianchi"
    ```
- **Summary**: `participants` is read from the note's frontmatter at every Processing and Regeneration (so a correction counts on Retry) and, if there are any, goes into the user message as `# Invited participants`. Rule: the invitation says who was asked to join, not who spoke; a Speaker's name can be one of them only when the Transcript makes it clear, or when there is exactly one invited participant and one Speaker. The names also help spell names right, like the Vocabulary.
- No calendar, no permission, no event: everything as in v1.

### Speaker names by hand

When the Summary cannot tell who a Speaker is, the user can say it:

- In the Meeting note's frontmatter, a `speakers` list written by the user (Takku never writes it), one entry per Speaker, with the Vocabulary's `=`:
  ```yaml
  speakers:
    - Speaker 1 = Mario Rossi
    - Speaker 3 = Anna Bianchi
  ```
- Read at every Processing and Regeneration. In the Transcript the paragraphs of a named Speaker show `**[00:42] Mario Rossi (Speaker 1):**`: the number stays, so the name can be changed and Retry applies the new one, and the Transcript is read back by its number. Speakers not listed stay *Speaker N*. Entries that do not match `Speaker <number> = <name>` are ignored.
- A Regeneration (audio deleted) rewrites the labels of the Transcript in the Vault with the names of that moment; the text stays as it is.
- **Summary**: the rule says that "Name (Speaker N)" is a name given by the user, certain: use it always.
- Typical use: after the first Summary, read the Transcript, add `speakers`, *Retry*.

### Marked moments

- While recording, **⌃⌥⌘M** (from any app) or *Mark this moment* in the menu marks the current time as important. For a second the red dot in the menu bar becomes a star; the menu shows "Marked moments: N". No sound: it would be recorded in the Others Track.
- The marks are saved in `marks.json` in the Recording folder (seconds from the start of the Meeting), at once, so they survive a crash.
- In the Transcript the paragraph a mark falls in (the last one starting at or before it, of either Track) starts with ⭐: `**[12:30] Speaker 2:** ⭐ So the deadline…`. The mark usually comes right after what mattered. Several marks in the same paragraph give one star. Being in the Transcript, the stars survive the audio and a Regeneration.
- **Summary**: rule "Paragraphs starting with ⭐ were marked as important by the user during the meeting: give them priority, like the topics of the personal notes." Stars the model copies into the Summary are removed with the cited times.
- If ⌃⌥⌘M is taken by another app, the menu says so, like for ⌃⌥⌘R.

### Screenshots

The screen of a moment kept in the Meeting note, without the model ever seeing it ([ADR 0011](adr/0011-screenshots-never-reach-the-model.md)).

- While recording, **⌃⌥⌘S** (from any app) or *Take a screenshot* in the menu takes a Screenshot and makes a Mark at the same moment: it counts in "Marked moments: N" and stars its paragraph. For a second the red dot becomes a camera; the menu shows "Screenshots: N". No shutter sound: it would be recorded in the Others Track.
- **What**: the whole display showing the frontmost window (the main display if there is none), at its native resolution, as JPEG (quality 0.8): about 0.5–1 MB on a Retina display.
- **Permission**: Screen Recording, asked in the welcome window as its last step, optional, and otherwise the first time ⌃⌥⌘S is pressed. Without it the Mark is made anyway and the menu shows "Screenshot not taken: allow Screen Recording in System Settings…", which opens them. macOS applies the permission when Takku is reopened: after the Meeting, not during it.
- **On disk**: at once in `screenshots/` in the Recording folder, so they survive a crash, named `2026-10-04 1430 - 12m30s.jpg` (Meeting start, then the time from the start; `1h05m30s` past the hour; ` (2)` when two fall in the same second). At the end of Processing they are copied into `Meetings/Screenshots/` in the Vault, only those not already there: a Retry overwrites nothing. The name does not follow the note's: Obsidian finds `![[…]]` by name anywhere in the Vault, and the rename does not touch it.
- **Transcript**: each Screenshot is an embed on its own line under the paragraph it falls in (the last one starting at or before it, like a Mark), several in time order; one taken before any speech goes before the first paragraph:

  ```markdown
  **[12:30] Speaker 2:** ⭐ So the deadline…

  ![[2026-10-04 1430 - 12m31s.jpg]]
  ```

  When the Transcript is read back (Regeneration) a line that only embeds an image (`![[….jpg]]`, `.jpeg`, `.png`, `.webp`, `.gif`, also with `|size`) is a Screenshot, not text of the paragraph: it is never sent to the model.
- **Summary**: each Screenshot goes under the first line of the Summary that cites the paragraph it falls in (its time, or a range with it), on its own line, 400 px wide (a click in Obsidian enlarges it) and indented so it stays inside that point. The model is not asked anything: Takku places them with the times the model cites for every point, before removing them (see *Cited times*). Several under the same point go in time order.

  ```markdown
  - The deadline moves to Friday
    ![[2026-10-04 1430 - 12m31s.jpg|400]]
  ```

- **Meeting note**: those the Summary did not place (no point cites their paragraph, taken before any speech, Summary failed, *Transcript* as Profile) go in the Managed section after the Summary (or the warning) and before `Full transcript: [[…]]`:

  ```markdown
  ### Screenshots

  **[12:31]** ![[2026-10-04 1430 - 12m31s.jpg]]
  ```

  The time comes from the file name; for an image named otherwise, from the paragraph it is under. When all are placed there is no heading.
- **Regeneration**: the list comes from the embeds in the Transcript in the Vault, and the new Summary places them again. An embed the user removed from the Transcript disappears from the note too; a file deleted while its embed stays shows as a broken link. Takku never deletes Screenshots from the Vault.
- The Summary model never receives them, nor their names, neither for the Summary nor for the title (asked on the Summary without them). The Hook does not change: the embeds in the note and in the Transcript name files in `Meetings/Screenshots/`, and the Hook runs in the Vault.
- If ⌃⌥⌘S is taken by another app, the menu says so, like for ⌃⌥⌘R.

### Imported audio

A recording made elsewhere (a voice memo on the iPhone, a lecture, a call recorded by another app, a video) becomes a Meeting without recording it again.

- *Import audio…* in the menu, when idle: a panel to choose one or more audio or video files (any format macOS decodes: m4a, mp3, wav, aiff, caf, and the sound of mp4 and mov videos, e.g. a Zoom or Teams recording or a screen recording). Each file becomes its own Meeting, processed in the queue like a recorded one, with the Template and the Summary Profile chosen in the menu. While a file is being converted the bar shows the hourglass and the menu "Importing <file>…".
- **Recording**: the audio is converted to mono 16 kHz AAC and written as the **Others** Track, in 5-minute Segments like a recorded one (same `SegmentedTrackWriter`), so Transcript, Speakers, Summary, Retry and retention work unchanged. There is no Me Track: the user's voice is one of the Speakers, and the Me level filter and the echo removal have nothing to do. The original file is only read, never moved or deleted.
- **Start**: when the file was recorded, from its metadata (`AVAsset.creationDate`: Voice Memos and most recorders write it); without it, the file's creation date. The end is the start plus the duration. The note is named after the start, like a recorded Meeting.
- **Meeting note**: created at once, not opened in the Editor (the "Summary ready" notification opens it). It takes the calendar event in progress at the start only when the start comes from the metadata: the creation date of a copied or downloaded file is when it was copied, and would pick an unrelated event.
- A file with no sound macOS can decode (not audio or video, or a video without sound) is not imported: the menu shows "Not imported: Cannot read the audio of <file>." and no Recording folder is left behind.
- Room capture (recording an in-person meeting with the microphone only) stays out: an in-person meeting recorded on the phone is imported instead.

### Call start and end

- Settings → *General* → *Suggest recording when a call starts* (on by default).
- Every 3 seconds Takku reads which processes are using an audio input (Core Audio process objects, `kAudioProcessPropertyIsRunningInput`; nothing is recorded or listened to). Takku itself is ignored. The app is named after the running app that owns the process (a browser helper becomes the browser).
- **Start**: when idle and another app has been using the microphone for 15 seconds without a break, one notification per stretch of use: "Looks like a call in Zoom" · "Start recording?", with a *Start meeting* button; clicking the notification starts too. Dictation apps used for a few seconds do not trigger it.
- **End**: while recording, if at some point another app was using the microphone and now none has been for 30 seconds, one notification: "The call seems over" · "Stop recording?", with a *Stop meeting* button. It comes again only if an app takes the microphone back and releases it again. Takku never stops by itself.
- These notifications are not sent while the corresponding action makes no sense (start while recording, stop while idle); a stale button does nothing.

### Hook

A Meeting can be taken elsewhere (Confluence, Notion, a git commit of the Vault) by a script of the user, without Takku knowing the service ([ADR 0007](adr/0007-hook-after-processing.md)).

- **Where**: `~/.takku/hooks/after-processing`, a single executable in any language. No setting: if the file exists, Takku runs it; if it does not, nothing happens. Several destinations are chained inside the script.
- **When**: after every Processing that ends *completed*: with no problems, warnings allowed (e.g. an incomplete Transcript), with or without a Summary (*Transcript* as Profile). That includes a successful Retry, with the audio or as a Regeneration, so the Hook runs again after every Retry. It does not run when Processing fails, including when only the Summary fails (the note and the Transcript are written, the Meeting is *failed*), nor without a Vault.
- **Arguments**: the absolute paths of the Meeting note and of the Transcript, in this order. Nothing else: no stdin (`/dev/null`), no payload, no environment variables of its own besides `PATH` (below). The note's frontmatter has the rest; the script uses `takku_id` to update what it created at an earlier run instead of creating it again.
- **Execution**: the Hooks run one at a time in a queue of their own, separate from Processing: a slow Hook does not hold up the next Meeting, and two runs for the same Meeting (a Retry while the Hook is still running) never overlap; the running one is not cancelled. Working directory: the Vault. `PATH`: Takku's, plus `/opt/homebrew/bin` and `/usr/local/bin` (an app started from the Dock does not have Homebrew's). After 5 minutes the Hook is terminated, together with the processes it started (its process group): SIGTERM, then SIGKILL 5 seconds later for whatever is still running.
- **Outcome**: exit code 0 is silent. A non-zero exit code, the timeout, or a file that exists but is not executable send one notification, "Hook failed" · "<note name>: see ~/.takku/hooks/after-processing.log". The Meeting stays *completed*; there is no automatic retry.
- **Log**: `~/.takku/hooks/after-processing.log`. Each run appends the date, the note name, the command to rerun it by hand from the Terminal (both paths quoted), the exit code (or *timeout*) and stdout and stderr. A file that is not executable gets "not executable: run `chmod +x ~/.takku/hooks/after-processing`". Past 1 MB, only the last half is kept.
- **Rerunning** a failed Hook is done by hand, with the command from the log: a Retry would also regenerate the Summary.
- **Permissions**: the Hook can use Takku's permissions (microphone, system audio, calendars), since macOS treats Takku as its responsible process. Accepted, see ADR 0007.
- **Where the data goes**: the Hook can send a Meeting anywhere, outside the EU too. As for Providers, it is the user's choice. The README lists the Hook in "Where your data is".
- No Settings section and no menu item: the Hook is documented in the README and in the guide on the site.

### Smaller changes

- **Distribution**: since 1.0.0 on GitHub Releases (a zip up to 1.8.0, then a disk image) and a Homebrew cask (`brew install --cask mameli/takku/takku`), signed with a Developer ID and notarized by `scripts/release.sh`, so Takku opens like any other app.
- **Update check**: Settings → *General* → *Check for updates* (on by default). At launch and once a day Takku asks GitHub for the latest release (`api.github.com/repos/mameli/Takku/releases/latest`, no data about the user or the Meetings, only the request). If its version (`v0.1.6` → `0.1.6`) is newer than the running one, the menu shows "Takku 0.1.6 is available…", which opens the release page. The README lists this request in "Where your data is".
- **Welcome window**: at launch while no Vault is chosen (in practice the first launch), and from *Set up Takku…* in the menu until then. Steps: Vault (`Vault.choose()`, shared with Settings) · microphone and system audio (the microphone through AVFoundation; the system audio has no request API, so a process tap runs for a second to make macOS ask, and whether it was allowed cannot be read) · transcription model (downloads and prepares the selected model, as the first Meeting would) · Summary (optional: opens Settings, links to the setup page) · Screenshots (optional: asks for Screen Recording, which macOS applies at the next launch; last, because the *Quit & Reopen* macOS offers would close the window and, with a Vault chosen, it does not open again) · Open at login and Calendar. *Done* closes it; nothing is saved besides the settings themselves.
- **Report a problem…** (menu, above *Settings…*): writes `Takku report <date>.txt` in the temporary folder (Desktop and Downloads would need a permission of their own) and shows it in Finder, then opens `github.com/mameli/Takku/issues/new` with the bug form's fields filled in through the query (`ProblemReport`). The file has the version and build, macOS, Mac model and memory, the install method (Homebrew if its Caskroom has Takku), the transcription model, the Summary as model plus *on this Mac* or *remote* (never the Profile's name or address, which can name a company) and `log show --last 3d` for the `app.takku.takku` subsystem. Nothing is sent by Takku.
- **Recent meetings → Show all in Obsidian…**: opens Obsidian's search on the Vault with the Meeting notes (`[takku_id] -path:"Meetings/Transcripts"`).
- **CI**: GitHub Actions runs `swift test` on `TakkuCore` and builds the app (signed ad hoc) at every push and pull request.
- **Code**: `SettingsView.swift` split by section; `MeetingProcessor.swift` without the retention and the notifications of the outcome, moved to their own types.
