---
name: meeting-prep
description: Use when the user wants to prepare for an upcoming meeting, a call with someone or a recurring sync, or asks what is still open with a person or project. Builds a brief from past meetings recorded with Takku.
---

# Preparing a meeting

Build a short brief from the user's past meetings, through the `takku` MCP tools (read only). Without them, use the `takku` command: `takku list --query NAME --json`, `takku search WORDS --json` and `takku get ID --json --no-transcript`, with the same fields.

1. Find the past meetings that matter: `list_meetings` with the person's name, the team or the recurring title as `query` (participants and speakers are matched), and `search_meetings` with the project or topic. Look back about two months unless the user says otherwise.
2. Read the latest three to five with `get_meeting` (summary first, `include_transcript: false`; the transcript only when a point is unclear).
3. Write the brief:
   - **Where things stand**: one or two lines.
   - **Open actions**: who owes what, from which meeting, and whether a later meeting closed it.
   - **Decisions already taken**, so they are not reopened by mistake.
   - **Open questions** and topics that came up without a conclusion.
   - **Suggested agenda** for the next meeting.
4. Cite each point with the meeting's date and title. Leave out what you cannot find instead of guessing.
