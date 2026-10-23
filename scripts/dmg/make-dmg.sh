#!/bin/bash
# Packs Takku.app into a disk image: the app and a link to Applications on the background drawn by
# scripts/dmg/background.py, with Takku's icon on the volume. Finder lays out the window (the
# first run asks to let the terminal control Finder), so it needs a logged-in Mac. Signing and
# notarization are up to the caller (release.sh).
#
#   scripts/dmg/make-dmg.sh <Takku.app> <Takku.dmg>
set -euo pipefail

app=$1
out=$2
here=$(cd "$(dirname "$0")" && pwd)
volume=/Volumes/Takku

if [[ -e $volume ]]; then
    echo "Eject $volume first: Finder would lay out that disk instead." >&2
    exit 1
fi

work=$(mktemp -d)
trap 'hdiutil detach -quiet -force "$volume" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/src/.background"
ditto "$app" "$work/src/Takku.app"
ln -s /Applications "$work/src/Applications"
cp "$here/background.tiff" "$work/src/.background/"
cp "$app/Contents/Resources/AppIcon.icns" "$work/src/.VolumeIcon.icns"

hdiutil create -volname Takku -srcfolder "$work/src" -fs HFS+ -format UDRW -ov "$work/rw.dmg" -quiet
hdiutil attach "$work/rw.dmg" -readwrite -noverify -noautoopen -nobrowse -quiet
xcrun SetFile -a C "$volume"

# Positions and size match scripts/dmg/background.py (640 × 400, plus the title bar).
osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Takku"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set bounds of container window to {200, 120, 840, 548}
        set options to icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 13
        set background picture of options to file ".background:background.tiff"
        set position of item "Takku.app" of container window to {175, 205}
        set position of item "Applications" of container window to {465, 205}
        -- Out of sight for those who show hidden files.
        set position of item ".background" of container window to {175, 700}
        set position of item ".VolumeIcon.icns" of container window to {465, 700}
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Finder writes .DS_Store a little after closing the window.
for _ in {1..20}; do
    [[ -f $volume/.DS_Store ]] && break
    sleep 0.5
done
[[ -f $volume/.DS_Store ]] || { echo "Finder did not save the window layout." >&2; exit 1; }
sync
hdiutil detach -quiet "$volume"
rm -f "$out"
hdiutil convert "$work/rw.dmg" -format ULFO -o "$out" -quiet
