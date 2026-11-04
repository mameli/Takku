---
name: takku-template
description: Use when the user wants to create, change or improve a Takku Template, the Markdown file that tells Takku how to write the summary of a kind of meeting, lecture or video, or asks why Takku's summaries come out a certain way.
---

# Writing a Takku Template

A Template is a Markdown file in `~/.takku/templates/`, one per kind of recording (a team meeting, a 1:1, a lecture, a video). Its name is the file name without `.md`, and it is what the user picks in Takku's menu or passes to `takku import --template`. `takku templates` lists them, the default marked.

## Format

```markdown
---
name: Video
summary_language: auto
folder: Videos
---
Instructions and structure, passed to the model as they are.
```

- `name`: shown in the menu; usually the file name.
- `summary_language`: `auto` (the language of the recording) or a code such as `en`, `it`, `fr` to always write in it.
- `full_text: true` (optional): the whole transcript rewritten clean, in blocks of about 10 minutes, instead of a summary. For lectures to study from.
- `folder` (optional): where a file imported with this Template gets its note, a folder of the notes folder (`Lectures`, `YouTube/Talks`). Not `Transcripts`, `Screenshots` or `_Templates`. Recorded meetings always go in `Meetings/`.

The body is free text: what kind of recording this is, then the sections, each a `###` heading with what goes under it. Read the ones in `~/.takku/templates/` before writing a new one, and start from the closest.

## What Takku already tells the model

Do not repeat these in a Template; change them only if the Template needs the opposite:

- who "Me" is (the user) and that "Speaker N" are other voices, named only when the transcript makes it clear;
- the user's personal notes and starred moments come first;
- actions as a `- [ ] What to do (Who)` checklist, only for things someone took on in the recording;
- the Vocabulary's spellings (`~/.takku/vocabulary.md`), and to leave out what makes no sense;
- the transcript may stop mid-sentence.

## What makes a Template work

- Say what the recording is and what it is not ("This is a lecture, not a meeting: one lecturer speaks…"). Without it the model looks for decisions and next steps.
- Give the order: topics in the order discussed, or fixed sections.
- For an optional section, say when to leave it out, "heading included"; otherwise it comes back empty.
- Name what to drop: greetings, sponsors, roll calls, problems with the call.
- End with "Write every heading, these ones included, in the language of the summary." so the headings follow the recording's language.
- Short and concrete: a rule the model can check beats an adjective ("one bullet per decision, with who and why" rather than "be thorough").

## Trying it

- Choose it in Takku's menu before a meeting, or import a file with it: `takku import file.m4a --template NAME`.
- On a meeting already processed, `takku regenerate ID --template NAME` writes the summary again from its transcript (the id from `takku list`). Each run is a summary request to the user's Profile.
- With *Keep a Summary log* on (Takku → Settings → Recordings), `~/.takku/summary-log/` holds one JSON per summary: the request with the Template as it was sent, and the model's reply. Compare the reply with the Template to see which rule was ignored; the user can write what was wrong in the entry's `comment` field.

Show the user the change before saving over a Template of theirs. A new Template is just a new file in `~/.takku/templates/`: Takku picks it up the next time its menu opens.
