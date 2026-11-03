#!/bin/bash
# Builds Takku in Release, signs it with the "Developer ID Application" certificate, has Apple
# notarize it (notarytool profile "takku", or $TAKKU_NOTARY_PROFILE), staples the ticket, packs it
# into a disk image (scripts/dmg/make-dmg.sh), signs and notarizes that too, publishes it as a
# GitHub Release tagged v<MARKETING_VERSION> (from Config/Base.xcconfig) and points the Homebrew
# cask in the tap (a clone of mameli/homebrew-takku, ../homebrew-takku or $TAKKU_TAP) to it. A
# published version is never replaced: Homebrew checks the disk image's SHA-256. The Release
# also carries a copy named Takku.dmg, so releases/latest/download/Takku.dmg (the download
# button on takku.app) always gives the latest version. Releases up to 1.8.0 carry a zip instead.
#
#   scripts/release.sh            build, sign and pack into build/release/, then ask before publishing
#                                 (a dry-run of the same commit is reused: no second build and notarization)
#   scripts/release.sh --dry-run  build, sign, notarize and pack only
#
# Once per Mac: the certificate from Xcode → Settings → Accounts → Manage Certificates, and
#   xcrun notarytool store-credentials takku --apple-id <Apple ID> --team-id <Team ID>
# with an app-specific password from account.apple.com.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^MARKETING_VERSION = //p' Config/Base.xcconfig)
tag="v$version"
app=build/release/DerivedData/Build/Products/Release/Takku.app
zip=build/release/Takku.zip
dmg="build/release/Takku-$version.dmg"
latest=build/release/Takku.dmg
built=build/release/commit
tap=${TAKKU_TAP:-../homebrew-takku}
cask="$tap/Casks/takku.rb"
identity="Developer ID Application"
notary=${TAKKU_NOTARY_PROFILE:-takku}

if [[ -n $(git status --porcelain) ]]; then
    echo "Commit or stash your changes first: the Release must match a commit." >&2
    exit 1
fi
if gh release view "$tag" >/dev/null 2>&1; then
    echo "Release $tag already exists: raise MARKETING_VERSION in Config/Base.xcconfig." >&2
    exit 1
fi
if [[ ! -f $cask || -n $(git -C "$tap" status --porcelain) ]]; then
    echo "The Homebrew tap must be a clean clone of mameli/homebrew-takku in $tap (or set TAKKU_TAP)." >&2
    exit 1
fi
# The Release notes are this version's CHANGELOG section, with links that work outside the repo.
# Its date is the day of publishing (UTC), written in the version commit.
released=$(sed -n "s/^## $version (\(....-..-..\))\$/\1/p" CHANGELOG.md)
if [[ -z $released ]]; then
    echo "CHANGELOG.md has no \"## $version (YYYY-MM-DD)\" section: rename \"## Unreleased\" in the version commit." >&2
    exit 1
fi
changes=$(awk -v head="## $version (" 'index($0, head) == 1 { on = 1; next } /^## / { on = 0 } on' CHANGELOG.md \
    | perl -0777 -pe 's{\]\((?!https?:|#|mailto:)([^)]+)\)}{](https://github.com/mameli/Takku/blob/main/$1)}g; s/^\s+|\s+$//g')

# A dry-run leaves the notarized disk image and the commit it was built from in build/release/:
# publishing that same commit reuses them instead of building and notarizing everything again.
if [[ ${1:-} != --dry-run && -f $built && $(cat "$built") == $(git rev-parse HEAD) && -f $dmg && -f $latest ]]; then
    xcrun stapler validate -q "$dmg" || { echo "$dmg has no notarization ticket: delete build/release and run again." >&2; exit 1; }
    echo "Reusing $dmg: built and notarized from this commit by the dry-run."
else
    # The Team ID is the certificate's organizational unit.
    team=$(security find-certificate -c "$identity" -p 2>/dev/null | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n 's/^ *organizationalUnitName *= *//p')
    if [[ -z $team ]]; then
        echo "No \"$identity\" certificate in the keychain: create it in Xcode → Settings → Accounts → Manage Certificates." >&2
        exit 1
    fi
    if ! xcrun notarytool history --keychain-profile "$notary" >/dev/null 2>&1; then
        echo "No notarytool profile \"$notary\": run xcrun notarytool store-credentials $notary --apple-id <Apple ID> --team-id $team" >&2
        exit 1
    fi

    rm -rf build/release
    # No get-task-allow entitlement: it is only for debugging (and notarization refuses it).
    # A secure timestamp is required by notarization.
    xcodebuild -project Takku.xcodeproj -scheme Takku -configuration Release \
        -derivedDataPath build/release/DerivedData \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp \
        clean build | grep -E "error: |BUILD"

    codesign --verify --strict --deep "$app"
    [[ $(codesign -dvv "$app" 2>&1) == *"Authority=$identity"* ]] || { echo "Not signed with the $identity certificate." >&2; exit 1; }

    notarize() {
        xcrun notarytool submit "$1" --keychain-profile "$notary" --wait --output-format json > build/release/notary.json || true
        if [[ $(plutil -extract status raw -o - build/release/notary.json 2>/dev/null) != Accepted ]]; then
            cat build/release/notary.json >&2
            id=$(plutil -extract id raw -o - build/release/notary.json 2>/dev/null)
            [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$notary" >&2
            echo "Notarization of $1 failed." >&2
            exit 1
        fi
    }

    # The app is notarized as a zip and the ticket stapled to it, so Gatekeeper accepts it offline
    # once it is in Applications too. Then the disk image around it is signed, notarized and stapled.
    ditto -c -k --keepParent "$app" "$zip"
    notarize "$zip"
    rm "$zip"
    xcrun stapler staple -q "$app"
    spctl --assess --type execute "$app" || { echo "Gatekeeper refuses the notarized app." >&2; exit 1; }
    scripts/dmg/make-dmg.sh "$app" "$dmg"
    codesign --sign "$identity" --timestamp "$dmg"
    notarize "$dmg"
    xcrun stapler staple -q "$dmg"
    spctl --assess --type open --context context:primary-signature "$dmg" || { echo "Gatekeeper refuses the disk image." >&2; exit 1; }
    cp "$dmg" "$latest"
    git rev-parse HEAD > "$built"
    echo "Ready: $dmg (notarized)"
fi

[[ ${1:-} == --dry-run ]] && exit 0
read -r -p "Publish $tag on GitHub? [y/N] " answer
[[ $answer == y ]] || exit 0

if [[ $(git rev-parse HEAD) != $(gh api "repos/{owner}/{repo}/commits/main" --jq .sha) ]]; then
    echo "Push main first: the tag is created on the commit GitHub has." >&2
    exit 1
fi
if [[ $released != $(date -u +%F) ]]; then
    echo "Note: CHANGELOG.md dates $version $released, but today is $(date -u +%F) (UTC): fix it in a later commit." >&2
fi
# What's new first, then how to update in plain words: Takku's menu brought here people who
# never saw GitHub up to 1.16.0 (from 1.16.1 it opens takku.app/update).
gh release create "$tag" "$dmg" "$latest" --target main --title "Takku $version" --notes-file - <<NOTES
### What's new

$changes

All versions: [CHANGELOG.md](https://github.com/mameli/Takku/blob/main/CHANGELOG.md)

---

### How to update

1. Download **[Takku-$version.dmg](https://github.com/mameli/Takku/releases/download/$tag/Takku-$version.dmg)**.
2. Quit Takku: click its icon at the top of the screen, then **Quit Takku**.
3. Open the downloaded file and drag **Takku** onto **Applications**. When your Mac asks, choose **Replace**.
4. Open Takku again. Your notes, settings and models stay as they are.

Step by step: [takku.app/update](https://takku.app/update). With Homebrew: \`brew upgrade --cask takku\`.

---

Apple Silicon Mac, macOS 15 or later. New to Takku? \`brew install --cask mameli/takku/takku\`, or download the disk image above, then see [takku.app/setup](https://takku.app/setup). Takku is notarized by Apple: it opens like any other app.
NOTES

# The cask points to this version's disk image. Pushed through gh, like the Release.
sha=$(shasum -a 256 "$dmg" | cut -d ' ' -f 1)
git -C "$tap" pull --ff-only -q
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" \
    -e 's/Takku-#{version}\.zip"/Takku-#{version}.dmg"/' "$cask"
git -C "$tap" commit -q -am "Takku $version"
git -C "$tap" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -q origin main
echo "Homebrew cask updated to $version."
