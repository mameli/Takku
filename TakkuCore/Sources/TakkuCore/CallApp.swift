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

    /// Call apps: a call there is suggested sooner than in any other app, which could be a
    /// dictation or a voice note. Browsers are not here: a call in a browser cannot be told from
    /// a voice message on a web page.
    static let callBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "com.apple.FaceTime",
        "Cisco-Systems.Spark",
        "com.webex.meetingmanager",
    ]

    public var isCallApp: Bool {
        bundleID.map(Self.callBundleIDs.contains) ?? false
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
