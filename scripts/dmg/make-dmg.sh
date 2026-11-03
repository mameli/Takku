#!/bin/bash
# Packs Takku.app into a disk image: the app and a link to Applications on the background drawn by
# scripts/dmg/background.py, with Takku's icon on the volume. The window layout is the .DS_Store
# saved in scripts/dmg/DS_Store, so packing needs neither Finder nor a free /Volumes/Takku.
# Signing and notarization are up to the caller (release.sh).
#
#   scripts/dmg/make-dmg.sh <Takku.app> <Takku.dmg>
#   scripts/dmg/make-dmg.sh --layout <Takku.app> <Takku.dmg>
#
# --layout has Finder lay out the window again and saves it in scripts/dmg/DS_Store: after
# changing the background or the positions. It needs a logged-in Mac, /Volumes/Takku free (Finder
# finds the disk by name) and, the first time, permission for the terminal to control Finder.
set -euo pipefail

layout=false
if [[ ${1:-} == --layout ]]; then
    layout=true
    shift
fi
app=$1
out=$2
here=$(cd "$(dirname "$0")" && pwd)

work=$(mktemp -d)
if $layout; then
    volume=/Volumes/Takku
    if [[ -e $volume ]]; then
        echo "Eject $volume first: Finder would lay out that disk instead." >&2
        exit 1
    fi
else
    volume=$work/mnt
fi
trap 'hdiutil detach -quiet -force "$volume" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/src/.background"
ditto "$app" "$work/src/Takku.app"
ln -s /Applications "$work/src/Applications"
cp "$here/background.tiff" "$work/src/.background/"
cp "$app/Contents/Resources/AppIcon.icns" "$work/src/.VolumeIcon.icns"
$layout || cp "$here/DS_Store" "$work/src/.DS_Store"

hdiutil create -volname Takku -srcfolder "$work/src" -fs HFS+ -format UDRW -ov "$work/rw.dmg" -quiet
if $layout; then
    hdiutil attach "$work/rw.dmg" -readwrite -noverify -noautoopen -nobrowse -quiet
else
    mkdir "$volume"
    hdiutil attach "$work/rw.dmg" -readwrite -noverify -noautoopen -nobrowse -quiet -mountpoint "$volume"
fi
xcrun SetFile -a C "$volume"

if $layout; then
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
    cp "$volume/.DS_Store" "$here/DS_Store"
    echo "Window layout saved in scripts/dmg/DS_Store."
fi
sync
hdiutil detach -quiet "$volume"
rm -f "$out"
# LZMA: about a sixth smaller than LZFSE, and opened by every macOS Takku runs on.
hdiutil convert "$work/rw.dmg" -format ULMO -o "$out" -quiet
