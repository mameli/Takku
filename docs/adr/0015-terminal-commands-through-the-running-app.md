# Terminal commands that change something go through the running app

`takku list`, `search`, `get` and `mcp` read the notes folder and exit without starting the app. Importing a file and regenerating a Summary cannot work that way: they need the Processing queue, the transcription models in memory and what the app knows about the Meeting being recorded. A second process doing the same work would transcribe in parallel with the app, keep a queue of its own and write the same `processing.json`.

So `takku import` and `takku regenerate` only **ask** the app. The command writes a request, a JSON file, in `~/Library/Application Support/Takku/Requests/`, and opens Takku if it is not running. The app reads that folder at launch and whenever it changes, handles one request at a time as the menu would (*Import audio…*, *Regenerate Summary*), and answers with a file next to it: the request taken, or why not. The command chooses the Meeting's `takku_id` itself, so it can print it at once and then follow the Meeting by reading its `processing.json` until Processing ends (`--wait`, the default). Stopping the command stops the waiting, never the Processing.

The command checks what it can before asking (the file exists, the Template and the Profile exist, the folder is valid), reading the same Settings and Templates the app reads: a typo gets an answer in the terminal, not a failed Meeting.

## Considered options

- **The command does the work itself**: two transcribers and two queues on the same Recordings. Rejected.
- **A URL scheme** (`takku://import?file=…`): any web page can open it, and the file named in it would be transcribed and sent to the Summary Provider. Rejected.
- **Apple Events or distributed notifications**: they need the app running, are lost if it quits, and give no answer to wait for.
- **A socket or XPC service**: an answer at once, but also the app running, and more code than a folder, for a command used now and then.

## The MCP server stays read only

An assistant reads untrusted text (web pages, mail, documents). With a tool that imports, a sentence in a page could have any audio file on the Mac transcribed and then read back through `get_meeting`, or spend the user's Takku Credit; a model on the Mac does not change that. The MCP server gets the read-only tools that help with the commands (`list_templates`, `list_profiles`, `meeting_status`), and changes stay with the user in the terminal.

## Consequences

- The request format is a contract between the command and the app of the same Takku. The app refuses a request of another version (the old app still running after an update) with an answer that says to quit and reopen Takku.
- The requests folder can be written by any process of the user, as `~/.takku/hooks/` can: such a process can already read the files and the notes itself.
- A file in Desktop, Documents or Downloads is read by Takku, not by the Terminal, so macOS asks Takku for that folder the first time; the panel of *Import audio…* never asked, because choosing the file grants it.
- `--folder` puts the note in a folder inside `Meetings/`. Takku remembers that folder in `processing.json`, so the note is still "where Takku created it" and gets its title at the end of Processing; `list`, `search`, the Hook and the lookup by `takku_id` already find notes in folders.
- An import arriving during a call is converted and queued at once, like a Meeting stopped just before the next one starts: Processing already runs while recording.
- Imports bring in more than calls (videos, lectures), and the folder is still `Meetings/`: renaming it would move every user's notes and break their Hooks and queries. To be decided apart, together with the word *Meeting* itself.
