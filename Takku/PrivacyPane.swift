import AppKit

/// The panes of System Settings → Privacy & Security that Takku sends the user to.
enum PrivacyPane: String {
    case microphone = "Privacy_Microphone"
    /// Screen & System Audio Recording: Screenshots and the system audio Track.
    case screenRecording = "Privacy_ScreenCapture"
    case calendars = "Privacy_Calendars"

    func open() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!)
    }
}
