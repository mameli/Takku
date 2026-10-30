import KeyboardShortcuts

/// Keyboard shortcuts that work in any app, chosen in Settings → General. By default ⌃⌥⌘R starts
/// and stops the Meeting, ⌃⌥⌘M marks a moment, ⌃⌥⌘S takes a Screenshot. Saved by KeyboardShortcuts
/// in the user defaults; a shortcut the user removed stays removed.
///
/// macOS does not refuse a combination another app already registered, so Takku cannot tell
/// when one is taken: Settings warns only about the system's own shortcuts.
extension KeyboardShortcuts.Name {
    static let startStopMeeting = Self("startStopMeeting", initial: .init(.r, modifiers: [.control, .option, .command]))
    static let markMoment = Self("markMoment", initial: .init(.m, modifiers: [.control, .option, .command]))
    static let takeScreenshot = Self("takeScreenshot", initial: .init(.s, modifiers: [.control, .option, .command]))

    static let takku: [Self] = [.startStopMeeting, .markMoment, .takeScreenshot]
}
