import Foundation

/// An app using the microphone, as `CallWatch` sees it.
public struct CallApp: Hashable, Sendable {
    /// The name shown in the suggestion.
    public let name: String
    /// The bundle identifier of the app, `nil` when not known.
    public let bundleID: String?

    public init(name: String, bundleID: String?) {
        self.name = name
        self.bundleID = bundleID
    }

    /// What an app on the microphone can be. Any other app (dictation like Dimmela or Handy,
    /// a recorder, Siri) is never a call: Takku does not suggest recording it.
    public enum Kind: Sendable {
        /// An app for calls: suggested after `CallWatch.callAppStartAfter`.
        case callApp
        /// A browser (Meet, Teams on the web) or a chat app with calls (WhatsApp, Telegram):
        /// it could also be a voice message, so it is suggested after `CallWatch.startAfter`.
        case mayBeCall
    }

    static let callApps: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "com.apple.FaceTime",
        "Cisco-Systems.Spark",
        "com.webex.meetingmanager",
        "com.hnc.Discord",
        "com.skype.skype",
    ]

    static let mayBeCallApps: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",
        "net.whatsapp.WhatsApp",
        "desktop.WhatsApp",
        "ru.keepcoder.Telegram",
        "org.whispersystems.signal-desktop",
    ]

    /// `nil` for an app that is not for calls.
    public var kind: Kind? {
        guard let bundleID else { return nil }
        if Self.callApps.contains(bundleID) { return .callApp }
        if Self.mayBeCallApps.contains(bundleID) { return .mayBeCall }
        return nil
    }

    /// Helper processes that capture the microphone for an app whose bundle identifier does not
    /// start theirs (`us.zoom.CptHost` for Zoom), lowercased.
    private static let hostOfHelper: [String: String] = [
        "us.zoom": "us.zoom.xos",
        "org.mozilla.plugincontainer": "org.mozilla.firefox",
    ]

    /// The bundle identifiers that may be the app of an audio process, to try in order: the host
    /// of a known helper, then the identifier itself and each shorter prefix of it
    /// (`com.google.Chrome.helper`, `com.google.Chrome`, `com.google`).
    public static func candidateBundleIDs(forAudioProcess bundleID: String) -> [String] {
        var components = bundleID.split(separator: ".").map(String.init)
        var prefixes: [String] = []
        while components.count >= 2 {
            prefixes.append(components.joined(separator: "."))
            components.removeLast()
        }
        let hosts = prefixes.compactMap { hostOfHelper[$0.lowercased()] }
        return hosts.prefix(1) + prefixes
    }
}
