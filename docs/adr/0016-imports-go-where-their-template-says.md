# Imports go where `--folder` or their Template says, outside `Meetings/` if asked

`takku import` brings in lectures, talks and videos as well as meetings, and the user does not want them all in `Meetings/`. Renaming `Meetings/` for everyone was considered and dropped: it would move every user's notes and break their own queries and bookmarks, to fix something only imports need. Instead an import can go in any folder of the notes folder: `takku import --folder Lectures/Law`, or the Template's `folder:` (`folder: YouTube` in `Video.md`), which also covers *Import audio…* from the menu. Without either, `Meetings/` as before. Recorded Meetings always go in `Meetings/`, whatever their Template.

The Transcript goes in a `Transcripts` folder next to the note, so nothing of the import lands in `Meetings/`. No note folder may be named `Transcripts` (or `Screenshots`, `_Templates`), so a file under such a folder is a Transcript.

Takku finds its notes by `takku_id` in the folders it knows, not in the whole notes folder, which can be a large Obsidian vault. A folder outside `Meetings/` is remembered when Takku first creates a note in it (the `noteFolders` default, read by the app and by `takku`); the lookup, *Recent meetings*, retention, `list`, `search`, `get` and MCP read `Meetings/` and those folders.

## Considered options

- **Rename `Meetings/` to `Takku/`** (implemented, then reverted): more cons than pros, above.
- **Transcripts always in `Meetings/Transcripts/`**: simpler lookup, but every import would still write in `Meetings/`.
- **Search the whole notes folder by `takku_id`**: no list to keep, but every lookup would read every Markdown file of the vault.
- **A folder setting for all imports**: one folder for lectures and videos alike; the Template already says what kind of thing it is.

## Consequences

- A note moved by hand into a folder Takku never wrote in is not found, as one moved out of `Meetings/` already was.
- `folder` in `takku list --json` and MCP is relative to `Meetings/` for notes there, and to the notes folder for the others.
