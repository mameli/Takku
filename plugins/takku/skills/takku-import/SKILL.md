---
name: takku-import
description: Use when the user asks to summarise, transcribe or take notes on an audio or video file, a recorded lecture, a voice memo, a podcast episode or an online video (YouTube and other sites yt-dlp supports) with Takku. Downloads the audio if needed, imports it with `takku import` and returns the note and its summary.
---

# Importing a recording into Takku

Takku transcribes a file on the Mac and writes a Markdown note with a summary in the user's notes folder. `takku import` asks the Takku app to do it (the app opens if it is not running) and waits for the note.

Import only what the user asked for. The transcript goes to the Summary Profile active in Takku, which may be a remote provider: for a private recording (a call, a medical visit, an interview) check with the user first if they did not choose the Profile.

## 1. Get a file

- **A local file**: any audio or video macOS can play (m4a, mp3, wav, mp4, mov…). Use its absolute path.
- **An online video or podcast**: download the audio with yt-dlp (`brew install yt-dlp ffmpeg` if missing). Quote the URL, and keep `--no-playlist`: a YouTube link copied from a playlist would otherwise download the whole playlist.

  ```sh
  yt-dlp --no-playlist -f 'ba[ext=m4a]/ba' -x --audio-format m4a \
    -o "$HOME/Movies/Takku/%(title)s.%(ext)s" --print after_move:filepath "URL"
  ```

  The last line printed is the file's path. Save outside Desktop, Documents and Downloads when you can: macOS asks Takku for access to those folders the first time.

## 2. Choose how Takku writes the note

- **Template**: `takku templates` lists them, the default marked. Pick by content: a video or talk → a video Template (`Video`), a lecture → `Lecture` (notes) or `Full text` (everything said), a meeting → the default. Without `--template` Takku uses the one chosen in its menu.
- **Folder**: a Template can say where its imports go (`folder:` in its frontmatter). `--folder Lectures/Law` puts the note in that folder of the notes folder instead; recorded meetings always stay in `Meetings/`.
- **Profile**: leave it to Takku unless the user names one. `takku profiles` lists them; `--profile transcript` writes no summary.
- **Context** (`--notes TEXT`): goes in the note's personal notes, which the summary reads. Give what the transcript cannot say: who speaks, which course, the video's channel and description. For a video: `--notes "$(yt-dlp --no-playlist --print 'Video by %(channel)s. %(description)s' "URL")"`.
- **Language** (`--language de`, or `it,en`): only when the recording is in a language the user has not ticked in Takku, or the detection got it wrong.
- **Title** (`--title`): the note's name; for a video, its title.

`--notes` and `--language` need Takku 1.19 or later: if `takku` answers `unknown option`, run the import again without them.

## 3. Import and wait

```sh
takku import "/path/to/file.m4a" --template Video --title "Title" --notes "…" --json
```

Without `takku` on the PATH, use `/Applications/Takku.app/Contents/MacOS/Takku`. The command waits until the note is written: about a minute for a short file, a few minutes for an hour (transcription runs on the Mac, then the summary). Give the shell command a long timeout, or run it in the background. Progress (`queued`, `processing`, `completed`) goes to stderr.

With `--json` stdout is an array, one object per file: `path` of the note, `summary` (the summary alone, `null` without one), `note`, `transcript`, `status` and `error`. Exit status 1 means a file failed: its `error` says why.

## 4. Answer

Give the note's path and the summary, or the part the user asked for. Do not paste the whole transcript.

## When something goes wrong

- *Takku did not take the request… quit Takku and open it again*: an older Takku is running; ask the user to quit it from the menu bar and open it again, then retry.
- *No notes folder is chosen*: the user sets one in Takku → Settings → Notes.
- *Not imported: Cannot read the audio*: the file has no audio macOS can decode; download it again as m4a.
- To redo only the summary, with another Template or Profile: `takku regenerate ID --template NAME` (the id is in the JSON, or from `takku list`).
- `takku status` lists what Takku is still recording or processing.
