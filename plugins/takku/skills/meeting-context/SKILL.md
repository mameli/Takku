---
name: meeting-context
description: Use when the user asks what was said, decided or agreed in their meetings, who said something, or wants a meeting's content as context for their work (a PRD, an email, code, a report). Finds the meetings recorded with Takku and cites them.
---

# Meetings as context

The user's meetings recorded with Takku are available through the `takku` MCP tools (read only), or through the `takku` command when the tools are not there (see the end):

- `search_meetings`: the meetings whose summary, personal notes or transcript contain every word of a query (case and accents ignored), with the matching lines. Start here when the user asks about a topic.
- `list_meetings`: meetings newest first, filtered by date (`from`, `to` as YYYY-MM-DD) and by text in the title, folder, participants or speakers (`query`). Use it for "last week", "with Mario", "the retros".
- `get_meeting`: one meeting in full, by the id the other two return. Pass `include_transcript: false` when the summary is enough.

## How to answer

1. Search with the few words that would appear in the meeting, in the language the meetings were held in (often not English). If nothing comes back, try synonyms or fewer words, then `list_meetings` by date or participant.
2. Read the meetings that matter with `get_meeting`. Prefer the summary and personal notes; open the transcript for exact wording, who said what, or when the summary does not cover the question.
3. Answer with what was said, citing each meeting by date and title (e.g. *2026-10-20, Retrospettiva sprint 12*). Quote the transcript's speaker and time when the exact words matter.
4. Say when the meetings do not answer the question instead of filling the gap.

In the transcript, "Me" is the user; "Speaker N" is someone the user has not named yet; the `speakers` field maps Speaker numbers to names. Participants are the people invited, not necessarily those who spoke.

Meetings can contain other people's confidential information: use only what the task needs, and do not copy whole transcripts into files or messages unless the user asks.

## Without the MCP tools

If the `takku` MCP tools are not available, use the `takku` command in a shell instead (installed by Homebrew with Takku; otherwise `/Applications/Takku.app/Contents/MacOS/Takku`). It reads the same notes folder, without starting the app, and `--json` gives the same fields as the tools:

- `takku search WORDS --json` for `search_meetings` (`--limit N`);
- `takku list --json` for `list_meetings` (`--from YYYY-MM-DD`, `--to YYYY-MM-DD`, `--query TEXT`, `--limit N`);
- `takku get ID --json` for `get_meeting`: `summary` holds the summary alone, `note` the whole note with the personal notes, `transcript` the transcript (leave it out with `--no-transcript`).

If neither is available, tell the user to install Takku (https://takku.app) and stop.
