import Foundation

/// Suggests starting a Meeting when another app keeps using the microphone (a call), and stopping
/// it when the call app lets it go. It never starts or stops anything itself. Fed every second
/// or so with the apps using an audio input, Takku excluded; times in seconds.
public struct CallWatch: Sendable {
    public enum Suggestion: Equatable, Sendable {
        /// "Looks like a call in <app>": start recording?
        case start(app: String)
        /// "The call seems over": stop recording?
        case stop
    }

    /// Using the microphone this long without a break is a call, not a dictation.
    public static let startAfter: TimeInterval = 15
    /// The same for a call app (`CallApp.Kind.callApp`), where a voice message is unlikely.
    public static let callAppStartAfter: TimeInterval = 5
    /// No app on the microphone for this long while recording: the call is over.
    public static let stopAfter: TimeInterval = 30
    /// An app back on the microphone sooner than this is still the same call (muted, or reconnecting):
    /// it is not suggested again.
    public static let sameCallWithin: TimeInterval = 60
    /// Updates further apart than this (the Mac asleep, a stalled loop) start every stretch of use
    /// again: the time between them says nothing about the microphone.
    public static let maxGap: TimeInterval = 10

    /// Since when each app has been using the microphone without a break.
    private var usingSince: [CallApp: TimeInterval] = [:]
    /// Apps already suggested (or recorded), with when they were last on the microphone.
    private var handled: [CallApp: TimeInterval] = [:]
    private var lastUpdate: TimeInterval?
    /// When an app was last seen on the microphone during the Meeting in progress.
    private var lastCallSeen: TimeInterval?
    private var isStopSuggested = false

    public init() {}

    /// Apps that are not for calls (`CallApp.kind` is `nil`) are ignored, as if off the microphone.
    public mutating func update(appsUsingInput allApps: Set<CallApp>, isRecording: Bool, now: TimeInterval) -> Suggestion? {
        let apps = allApps.filter { $0.kind != nil }
        if let lastUpdate, now - lastUpdate > Self.maxGap { usingSince = [:] }
        lastUpdate = now
        usingSince = usingSince.filter { apps.contains($0.key) }
        for app in apps where usingSince[app] == nil { usingSince[app] = now }
        handled = handled.filter { now - $0.value < Self.sameCallWithin }
        for app in apps where handled[app] != nil { handled[app] = now }

        guard isRecording else {
            lastCallSeen = nil
            isStopSuggested = false
            let call = usingSince
                .filter { handled[$0.key] == nil && now - $0.value >= Self.startDelay(for: $0.key) }
                .min { $0.value < $1.value }?.key
            guard let call else { return nil }
            handled[call] = now
            return .start(app: call.name)
        }

        // A call going on while recording needs no suggestion, not even after the stop.
        for app in apps { handled[app] = now }
        if !apps.isEmpty {
            lastCallSeen = now
            isStopSuggested = false
            return nil
        }
        guard let lastCallSeen, !isStopSuggested, now - lastCallSeen >= Self.stopAfter else { return nil }
        isStopSuggested = true
        return .stop
    }

    private static func startDelay(for app: CallApp) -> TimeInterval {
        app.kind == .callApp ? callAppStartAfter : startAfter
    }
}
