#!/usr/bin/env python3
"""Takku Hook: copies each meeting note to Notion, as a page under a page of your choice.

Install it as ~/.takku/hooks/after-processing (see the README, "Hook"). Takku runs it with
the paths of the meeting note and of the Transcript; you can also run it yourself:

    ~/.takku/hooks/after-processing "/path/to/Vault/Meetings/2026-10-15 1430 - Weekly sync.md"

The first run for a meeting creates the page; later runs (after a Retry) replace its content,
so a meeting is never copied twice. Which page belongs to which meeting is remembered in
~/.takku/hooks/notion-pages.json, by the note's takku_id. Screenshots are not copied: they
stay in the vault.

Needs Python 3 (from Homebrew or the Xcode Command Line Tools) and nothing else.
"""
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

# The page the meetings go under: the 32 characters at the end of its link in Notion.
PARENT_PAGE_ID = ""
# Where the Notion integration token is kept in the macOS Keychain.
KEYCHAIN_SERVICE = "takku-notion"

API = "https://api.notion.com/v1"
NOTION_VERSION = "2026-03-11"
PAGES_FILE = Path.home() / ".takku" / "hooks" / "notion-pages.json"


def read_note(path):
    """The note's takku_id, title and body as Markdown for Notion."""
    text = Path(path).read_text(encoding="utf-8")
    frontmatter, body = "", text
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            frontmatter, body = text[4:end], text[end + 5:]
    match = re.search(r"^takku_id:\s*(\S+)", frontmatter, re.MULTILINE)
    if not match:
        sys.exit(f"No takku_id in {path}: not a Takku meeting note.")

    body = re.sub(r"%%.*?%%", "", body, flags=re.DOTALL)  # Obsidian comments (Takku's markers)
    body = re.sub(r"^Full transcript: \[\[.*\]\]\s*$", "", body, flags=re.MULTILINE)  # a link only Obsidian can follow
    # Screenshots stay in the vault: their line goes, with the time before an unplaced one
    body = re.sub(r"^[ \t]*(\*\*\[[^\]]*\]\*\*[ \t]*)?!\[\[[^\]]+\]\][ \t]*$\n?", "", body, flags=re.MULTILINE)
    body = re.sub(r"!\[\[[^\]]+\]\]", "", body)  # any other embed
    body = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", body)  # [[note|text]] -> text
    body = re.sub(r"\[\[([^\]]+)\]\]", r"\1", body)  # [[note]] -> note
    body = re.sub(r"\n{3,}", "\n\n", body).strip() + "\n"
    return match.group(1), Path(path).stem, body


def token():
    result = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"], capture_output=True, text=True
    )
    if result.returncode != 0:
        sys.exit(f'No Notion token in the Keychain: run  security add-generic-password -a "$USER" -s {KEYCHAIN_SERVICE} -w')
    return result.stdout.strip()


def notion(method, path, body):
    request = urllib.request.Request(
        API + path, method=method, data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token()}",
            "Content-Type": "application/json",
            "Notion-Version": NOTION_VERSION,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"Notion answered {error.code}: {error.read().decode(errors='replace')}")


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: after-processing <meeting note> [<transcript>]")
    if not PARENT_PAGE_ID:
        sys.exit(f"Set PARENT_PAGE_ID in {sys.argv[0]}.")
    takku_id, title, markdown = read_note(sys.argv[1])
    pages = json.loads(PAGES_FILE.read_text()) if PAGES_FILE.exists() else {}

    if takku_id in pages:
        notion("PATCH", f"/pages/{pages[takku_id]}/markdown", {
            "type": "replace_content",
            "replace_content": {"new_str": markdown},
        })
        print(f"Updated in Notion: {title}")
    else:
        page = notion("POST", "/pages", {
            "parent": {"page_id": PARENT_PAGE_ID},
            "properties": {"title": {"title": [{"text": {"content": title}}]}},
            "markdown": markdown,
        })
        pages[takku_id] = page["id"]
        PAGES_FILE.write_text(json.dumps(pages, indent=2))
        print(f"Created in Notion: {title} ({page.get('url', page['id'])})")


if __name__ == "__main__":
    main()
