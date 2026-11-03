# Takku updates itself with Sparkle

Up to 1.16.1 a new version meant downloading the disk image, quitting Takku and dragging the new one into Applications. People who are not technical got stuck on it: the menu opened GitHub's release page, a page they had never seen ("What do I download? CHANGELOG.md?"). Since 1.17.0 Takku installs updates itself, with [Sparkle](https://sparkle-project.org) 2: *Takku … is available…* in the menu, or *Install…* in Settings → About, opens Sparkle's window with what is new and *Install Update*; Takku downloads the disk image, replaces itself and opens again.

Sparkle was chosen over an updater of our own (download, verify, swap the bundle, relaunch): it already handles the parts that are easy to get wrong, such as verifying what was downloaded, replacing a running app, relaunching it and keeping the permissions, and every Mac app outside the App Store users know uses the same window.

- **Trust**: the appcast and the disk image come from GitHub, but Takku installs an update only if its EdDSA signature matches the public key in Takku's Info.plist (`SUPublicEDKey`), and Sparkle checks that the new app has the same Developer ID. The private key is in the keychain of the Mac that publishes (account `takku`, from Sparkle's `generate_keys`) and must be backed up with the Developer ID certificate: losing it means no Takku can install updates until users install a new version by hand.
- **Feed**: `appcast.xml` is published as a file of every GitHub Release, and Takku reads `releases/latest/download/appcast.xml`. It never moves and does not depend on takku.app being deployed. It holds the latest version only, with the CHANGELOG section as its notes.
- **Never during a Meeting**: a relaunch would stop the recording or the Processing, so it waits until neither is in progress (`shouldPostponeRelaunchForUpdate`).
- **No window by itself**: the daily check adds the version to the menu and to Settings → About (Sparkle's gentle reminders); Sparkle's window opens only when the user chooses it. *Check for updates* in Settings turns the daily check off. Sparkle sends no system profile.
- **Signing**: Xcode leaves Sparkle's helpers (Autoupdate, Updater.app, the XPC services) signed ad hoc; `release.sh` signs each with the Developer ID, inside out, before notarization.

## Consequences

- Versions up to 1.16.1 cannot update themselves: their users update by hand once more (takku.app/update).
- The Homebrew cask says `auto_updates true`: `brew upgrade` without the cask's name leaves Takku to update itself.
- A Debug build can try an update with `-testUpdateFeed <URL>`, an appcast served locally.
