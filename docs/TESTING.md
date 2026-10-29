# Takku v1 manual tests

Manual checks to run before using Takku for real meetings. Each one says what to do and what must happen. Labels are the English ones; on a Mac set to Italian the app shows the Italian translation (e.g. *Start meeting* = *Avvia riunione*).

Before starting: Takku running from the menu bar (notebook icon), Vault and a Summary Profile configured. **With a Profile outside the EU (e.g. OpenRouter) use test recordings only**: your own voice, public videos, never work meetings.

## Icons

- [x] **App icon**: Finder and notifications show the orange notebook.
- [x] **Menu bar**: the notebook outline and handwriting are crisp on light and dark menu bars and when the menu is selected. Recording still shows a red dot; Processing still shows an hourglass.

- [ ] **Open at login**: Settings → *General* → *Open at login* on → Takku is in System Settings → General → Login Items; log out and back in → Takku is in the menu bar. Turn it off → it disappears from Login Items.

- [ ] **First use**: move `~/Library/Application Support/Takku/Models` to the Trash, start a Meeting → the menu shows "Downloading transcription model… N%" rising, then "Preparing transcription model, first time only", then nothing; the Meeting is transcribed. The menu does not blink while the percentage changes.

- [ ] **Parakeet**: with Models in the Trash, Settings → *Transcription* → the download icon on Parakeet v3 → percentage, then "Preparing…" while macOS compiles it, then its ⋯ with *Use* and *Delete* appears. *Use* on Parakeet v3, record a Meeting with long and short replies → the Transcript is in the Meeting language, with sentences and times; note any reply in the wrong language.
- [ ] **Parakeet Ultra**: the same steps with Parakeet Ultra; *Retry* on a Meeting transcribed with Parakeet v3 transcribes it again with Ultra. *Delete* on Ultra leaves Parakeet v3 downloaded.
- [ ] **Parakeet, other languages**: with Parakeet Ultra and Italian and English ticked, record a Meeting where a video in German plays for a few seconds → its sentences are missing from the Transcript and the log says "sentences in another language dropped"; the Italian and English sentences around it are there.
- [ ] **Transcription models**: Settings → *Transcription* → the download icon on Small → percentage, then its ⋯ with *Use* and *Delete* appears; *Download* on the model in use → the menu shows the percentage, and nothing once it is done; *Use* → "In use" moves to Small; a Meeting is transcribed with Small; *Retry* on an older Meeting with Large v3 Turbo in use transcribes it again with Large. *Delete* on Small brings back *Download*.

## 1. Recording

- [x] **Start from the menu**: *Start meeting* → the red dot appears in the bar, Obsidian opens `Meetings/<date> <time> - Meeting.md`.
- [x] **Duration**: open the menu while recording → first line "Recording · mm:ss".
- [x] **Shortcut**: ⌃⌥⌘R from another app starts, ⌃⌥⌘R again stops.
- [x] **Template during the call**: change *Template* from the menu while recording → the Summary follows the last Template chosen.
- [x] **Profile during the call**: the *Summary Profile* menu is hidden while recording (it is fixed at the start).

## 2. Processing

- [x] **Notes Template**: the Summary has the topics in Meeting order, with bullets and sub-bullets, and *Next steps* at the end as a "What to do (Who)" checklist.
- [x] **Personal notes**: write a few lines under `## Personal notes` during the call → after the stop they are untouched and the Summary gives those topics priority.
- [x] **Summary**: after the stop an hourglass in the bar, then the "Summary ready" notification; the note has the Summary, the Transcript link and the frontmatter (duration, language, template, provider).
- [x] **Title and rename**: the note is no longer "… - Meeting" but "… - <title>"; the Transcript in `Transcripts/` has the same name with "(transcript)". With the note open and Obsidian in front, Obsidian shows the renamed note, not the previous one.
- [x] **Notification click**: opens the note in Obsidian.
- [x] **Note renamed by you**: rename the note during the call → Takku finds it and does not rename it.
- [x] **English meeting**: a test with an English video → Transcript and Summary in English.
- [x] **Short first sentence**: say only "ok" or "sì" at the start, then talk for a minute → the first sentence is transcribed in the Meeting language, not translated.
- [x] **Other Summary language**: a Template with `summary_language: fr` → Summary in French from an Italian meeting.

## 3. Queue and recent meetings

- [x] **Two Meetings in a row**: stop the first one and start the second right away → the menu shows the current Meeting, its phase and "1 more queued", then two notifications. With a long Summary the phase advances through "Writing Summary · part N/M" and "Merging Summary"; with the first diarization it also shows "Preparing speaker recognition".
- [x] **Recent meetings → Open note**: opens the right note, even if you renamed or moved it.
- [ ] **Meeting deleted from the Vault**: delete a Meeting note in Obsidian, open the menu → *Recent meetings* no longer lists it (an older Meeting takes its place); rename a note → the menu shows the new name.
- [ ] **Templates folder**: move `~/.takku` to the Trash, launch Takku → `~/.takku/templates/Notes.md` is back and is the default Template, also with no Vault chosen.
- [ ] **New Template**: Settings → *Notes* → *New Template…* → type a name → *Create* → the row appears, nothing opens; its ⋯ → *Edit With* → an editor → `~/.takku/templates/<name>.md` opens there; change instructions and sections and save.
- [x] **Default Template**: the new Template's ⋯ → *Use as Default* → *Default* moves next to it, the next Meeting starts with it.
- [x] **Delete Template**: ⋯ → *Move to Trash…* → confirm → the row disappears with no message, the file is in the Mac Trash; if it was the default, Notes is back. Notes has no *Move to Trash…*.
- [ ] **Regenerate with another Template**: choose another Template in the menu → *Recent meetings* → a Meeting → *Regenerate Summary* → the Summary follows the new Template and reads the current Transcript, even while the audio exists.
- [ ] **Regenerate without audio**: Settings → *Recordings* → ⋯ → *Delete audio…* → *Regenerate Summary* on a Meeting → the Summary is made again from the Transcript in the Vault, duration and Transcript do not change.
- [ ] **Reprocess Recording**: edit a Transcript by hand → *Reprocess Recording…* → *Cancel* leaves it unchanged; choose the action again and confirm → the Transcript is rebuilt from the audio and those edits are replaced. The menu shows Transcribing and Identifying speakers because the previous transcription and Speaker caches are ignored, also with the same model. The action is not offered once the audio is deleted.
- [ ] **Duplicate `takku_id`**: duplicate a Meeting note and its Transcript in the Vault, keeping the frontmatter unchanged. With the original note path and Transcript link intact, Processing updates only the linked originals. Remove that link and make the saved note path stale → Open note/Transcript and Regenerate report the duplicate paths and change neither copy. Cleanup keeps the local Transcript when the Vault copy is ambiguous.
- [ ] **Damaged manifests**: in a sandboxed Recording, corrupt `me-segments.json` while `recording.json` is valid → Processing still uses the valid manifest. Remove `recording.json` and interrupt the state at `.recording` → relaunch reports that the Segment list is unreadable and preserves all audio. Repeat with a missing list but an existing Track Segment, and with missing/corrupt `processing.json`: no partial recovery or cleanup, and a clear "Audio kept" error.
- [ ] **Deleted Profile**: start a Meeting with a Profile, delete that Profile in Settings before the Summary → the note says the Profile was deleted; choose another Profile and *Regenerate Summary* → Summary written.
- [ ] **New Profile**: *Add Profile* → the menu still shows the Profile active before (or *Transcript*) until *Use for Summaries*.
- [ ] **Recordings in Settings**: the space used matches the folder opened by ⋯ → *Show in Finder*; *Delete audio…* asks for confirmation and brings it to zero.
- [ ] **Summary log**: after a Meeting, `~/.takku/summary-log/` has one JSON file named date, Template and model, with `about` and a `single` and a `title` call whose request has the Transcript; no Profile address in it. A Retry adds a second file. Settings → *Recordings*: the log's size matches the folder, *Delete log* asks for confirmation and brings it to zero; with *Keep a Summary log* off a Retry adds nothing.
- [x] **Retry**: turn off the internet connection, record a short Meeting → "Processing failed" and ⚠️ in the note, in the menu and inside that Meeting's submenu; reconnect and *Regenerate Summary* → Summary generated.

## Editor

- [x] **Default**: a Mac where *Editor* was never changed → Settings → *Obsidian Vault* → *Editor* says *Obsidian*, with no line below it; every note opens in Obsidian as before.
- [x] **Zed**: *Editor* → Zed → a notification asks to turn on autosave in Zed; choosing Zed again shows none. *Start meeting* → the note opens in Zed at once; *Recent meetings* shows *Open Vault in Zed…* and it opens the vault as a project; the "Summary ready" click and *Open note* open the note in Zed.
- [x] **Rename in Zed**: with the vault open in Zed and the cursor in the note, let a Meeting finish → the Zed tab takes the new name and shows the Summary without leaving the note; Takku does not bring Obsidian forward.
- [ ] **Another event in Zed**: with the cursor in the note, pick another event in *Calendar event* → the Zed tab takes its name and, a moment later, shows its participants.
- [x] **Editor without folders**: *Editor* → TextEdit → *Recent meetings* shows *Show Vault in Finder…* and the Finder selects the vault.
- [x] **Back to Obsidian**: *Editor* → Obsidian → no notification, *Show all in Obsidian…* is back.
- [x] **Uninstalled editor**: `defaults write app.takku.takku editor com.example.missing` → *Editor* says *Obsidian* with the "no longer installed" line; notes open in Obsidian.

## Microphone without echo cancellation

- [x] **Call app hears you**: built-in microphone and speakers, Teams → *Settings → Devices → Make a test call* with Takku closed, then while Takku records, then after the stop with Takku still open → your voice plays back at the same volume all three times. *System Settings → Sound → Input level* moves while you talk during the recording.
- [ ] **Echo on the speakers**: a call on the Mac speakers where you mostly listen and reply now and then → the Transcript has your replies as Me, and the others' sentences only once, as theirs; no short English or nonsense Me sentences ("Oh yeah", "The five.") while the others talk.
- [ ] **Quiet reply**: say "sì" or "mm-hmm" softly while the others talk → it stays in the Transcript.
- [ ] **Typing**: type on the keyboard for a minute without talking during a Meeting → no made-up Me sentences ("Grazie.") in the Transcript.

## Speakers

- [ ] **First use**: move `~/Library/Application Support/Takku/Models/fluidaudio/nemotron-3-diarization` to the Trash, record a call with two or three other people → the Transcript has *Speaker 1*, *Speaker 2*… instead of *Others*, with the turns matching who spoke; the model is back in that folder. After updating from 1.10.0, *Retry* on a Meeting with its audio diarizes it again (the log says so) and `fluidaudio/speaker-diarization` is gone.
- [ ] **Names in the Summary**: in a call where someone is called by name and answers → the Summary uses that name for their points and actions; for someone never named it writes "Speaker N" only as who takes on an action, never in a heading or in the other bullets.
- [ ] **Offline**: with the diarization model deleted and no internet, *Retry* on a Meeting with its audio → the Transcript has *Others*, the menu and the notification say "Speakers not told apart: …", the Summary is written anyway.
- [ ] **Old Transcript**: *Retry* without audio on a Meeting processed before Speakers existed → the Summary is made from the Transcript with *Others*.

## Vocabulary

- [ ] **Edit Vocabulary With**: Settings → *Notes* → *Vocabulary* → *Edit Vocabulary With* → the menu lists only text editors with their icon (no Safari, Pages or Numbers), the default for Markdown first with *(default)*; choose one → `~/.takku/vocabulary.md` is created with the explanation text and opens in that app; the row says *No terms yet*. Add `- Scaleway = scale uai | our EU cloud provider`, go back to the Settings window → *1 term* with *Scaleway* below; with more than four terms the first four and *and N more*.
- [ ] **Variants in the Transcript**: add a term with a variant Parakeet really gets wrong in your voice, record a short Meeting saying it → in the Transcript file the term is written right; the Meeting note's Summary writes it right too.
- [ ] **Terms in the Summary**: say a term that is in the Vocabulary but write no variant for it, with recognition getting it wrong → the Summary spells the term right when the context makes it clear, and leaves other doubtful words alone.
- [ ] **Short terms**: a term that sounds like common words (like "Takku" next to "meno", "sono") → ordinary sentences with "meno" or "sono" are not changed, in the Transcript or in the Summary.
- [ ] **Retry with a new variant**: add a variant for a word that is wrong in an older Meeting still having its audio → *Retry* → the Transcript file has the term. Without the audio, *Retry* does not touch the Transcript text.
- [ ] **Transcript only**: *Summary Profile* → *Transcript*, record a Meeting saying a word that has a variant → the variant is replaced in the Transcript even with no Summary.
- [ ] **No Vocabulary file**: delete `~/.takku/vocabulary.md` → Meetings are processed as before, *No terms yet*.

## 4. Edge cases

- [x] **AirPods from the start**: AirPods connected before starting, not in a call → the Me Track records (there is a `me-000.m4a`), even though macOS switches them to call mode.
- [ ] **Microphone change**: during a Meeting connect or remove the AirPods, then keep talking → your sentences after the change are in the Transcript, at the right time compared with the others'.
- [x] **Transcript only**: *Summary Profile* → *Transcript* (the Template menu disappears), record a Meeting → the note holds only the "Full transcript" link, no warning, notification "Transcript ready". Then choose a Profile in the menu and *Regenerate Summary* → the Summary is written.
- [ ] **Failed Retry keeps the previous result**: complete a Meeting, turn off the internet and *Regenerate Summary* → the menu and notification report the error, but the previous Summary and Transcript in the Vault are unchanged.
- [ ] **No Vault**: with no Vault configured, process a Meeting → the notification and *Recent meetings → Open Transcript* open the local Transcript. *Settings → Recordings → Delete audio…* deletes the audio but keeps that only copy of the Transcript.
- [ ] **Screenshot just before Stop**: take a Screenshot and stop immediately → Processing waits for the capture; the image and its Mark are in the note and Transcript. Start another Meeting right away → its Screenshot count is not incremented by the old capture.
- [x] **Quit during Processing**: stop a Meeting and quit Takku right away → at the next launch Processing resumes by itself.
- [x] **Italian interface**: `defaults write app.takku.takku AppleLanguages -array it`, restart Takku → menu, Settings and notifications in Italian (`defaults delete app.takku.takku AppleLanguages` to go back).
- [x] **Wrong key**: in Settings replace the key with a random one → *Test connection* shows the provider's error; then put the right one back.

## v2

- [ ] **Silent Track**: System Settings → Privacy & Security → Screen & System Audio Recording, turn Takku off; start a Meeting with a video playing → after 2 minutes the menu shows "⚠️ No sound from the system audio for 2 min" and a notification says to check that setting. Turn it back on. In a normal call where the others are quiet for 2 minutes the menu line may appear, with no notification.
- [ ] **Meeting languages**: Settings → *Transcription* → *Meeting languages*, tick only French, record a French video → Transcript in French. Tick Italian, English and French, record each → each in its language. The last ticked language cannot be unticked.
- [ ] **Language migration**: before updating, `defaults write app.takku.takku language en` → after updating only English is ticked.
- [ ] **Calendar**: *Use the calendar* on → macOS asks for access; an event with invited people in progress, start a Meeting → the note is named after the event, `participants` lists them (not you, not rooms, not distribution lists); after Processing the note keeps that name. Deny access in System Settings → the switch is off when Settings opens again.
- [ ] **Another calendar event**: two events, one ending and one starting within 10 minutes (or two at the same time), start a Meeting → the menu's *Calendar event* lists both, one ticked; pick the other → the note takes its name and `participants`, and Obsidian shows it under the new name; pick *None* → provisional name, no `participants`, and after Processing a generated title. Rename the note by hand, then pick another event → the name stays, `participants` changes.
- [ ] **Speaker names**: after a Meeting with two Speakers, choose *Recent meetings → Name speakers…* → the window lists both, with the calendar participants as suggestions → assign *Mario Rossi* to Speaker 2, then *Save and Regenerate* → the Transcript shows *Mario Rossi (Speaker 2)* and the Summary uses the name. Change it in the note's frontmatter and *Regenerate Summary* again, also once the audio is deleted → the Transcript follows.
- [ ] **Marks**: ⌃⌥⌘M during a Meeting from another app → the dot becomes a star for a second, the menu shows "Marked moments: 1"; after Processing the paragraph just before has a ⭐ and the Summary covers it.
- [ ] **Call suggestions**: idle, join a Meet, Zoom or Teams call → within 20 seconds "Looks like a call in <app>" with *Start meeting*, which starts. Leave the call → within 35 seconds "The call seems over" with *Stop meeting*. A 5-second dictation with another app suggests nothing. Turn it off in Settings → no notifications.
- [ ] **Update check**: with `MARKETING_VERSION` lowered in a Debug build, the menu shows "Takku <latest> is available…", which opens the release page.
- [ ] **Welcome window**: in a Debug build `open Takku.app --args -showWelcome YES` → *Welcome to Takku* opens in front (on a Mac with no Vault, also without the argument, and the menu has *Set up Takku…*). *Choose…* a folder (it is saved for real: choose your Vault again afterwards) → the path appears, step 1 gets a check. With `tccutil reset Microphone app.takku.takku` and `tccutil reset AudioCapture app.takku.takku` first, *Allow microphone and system audio* → macOS asks for both. *Download and prepare* with the model deleted → percentage, then preparing, then a check. *Done* closes it; launching again with a Vault does not show it.
- [ ] **Report a problem**: menu → *Report a problem…* → Finder shows `Takku report <date>.txt` with version, Mac, models and the logs of the last 3 days (no Profile name or address); the browser opens the GitHub bug form with version, macOS, transcription model and Summary filled in (and *Homebrew* when installed with it).
- [ ] **Show all in Obsidian**: *Recent meetings* → *Show all in Obsidian…* → Obsidian's search lists the Meeting notes, not the Transcripts.
- [ ] **Import audio**: record a voice memo of two people on the iPhone, AirDrop it to the Mac → menu → *Import audio…* → choose it → the hourglass, "Importing <file>…", then "Summary ready"; the note starts as "Imported recording queued for Processing" and is named after the time of the memo (not the time of the import) and after the calendar event of that time, the Transcript has *Speaker 1*, *Speaker 2*. Choose two files at once → "Importing file 1/2", then 2/2, and two Meetings. Import the mp4 of a Zoom or Teams recording → a Meeting from its sound. Choose a text file renamed `.m4a`, or a video without sound → "Not imported: Cannot read the audio of ….", nothing in *Recent meetings*. *Retry* on the imported Meeting → transcribed from the cache.
- [ ] **Import an old file**: import a memo recorded months ago with five newer Meetings present → it appears first in *Recent meetings*, also after relaunch, while its note keeps the original date. After the next launch and daily cleanup its converted audio is still there for the configured retention period from the import, even if Processing failed.
- [ ] **Import with unreadable packets**: import the partially damaged AAC fixture → conversion succeeds, but Processing finishes with a warning listing every skipped interval's source start/end and saying that the Transcript and Summary may be incomplete. The warning survives relaunch before Processing and also appears without a Vault; a clean file produces no warning.
- [ ] **Hook**: `~/.takku/hooks/after-processing` with `#!/bin/sh` and `echo "$1 | $2"; which jq`, `chmod +x` → after a test Meeting `~/.takku/hooks/after-processing.log` has the note and the Transcript paths and Homebrew's `jq`, no notification. *Retry* → a second entry. Add `exit 1` → *Retry* → "Hook failed" notification, the Meeting is not marked failed; the command in the log, pasted in the Terminal, runs the script again. `chmod -x` → *Retry* → "Hook failed", and the log says to run `chmod +x`. Delete the file → *Retry* → nothing new in the log.

## 5. When you set them up

- [ ] **EU Provider** (e.g. Mistral): new Profile with key → *Test connection* → a test Meeting → choose it in the menu and *Retry* on an older Meeting to compare the Summaries.
- [x] **Local server** (llama.cpp): new Profile without key, `http://localhost:8080/v1`, max context equal to the server's (`llama-server -c 32768`).

If something goes wrong: the ⚠️ message in the menu and in the note says why; copy it as it is.
