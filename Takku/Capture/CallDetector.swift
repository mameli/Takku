import AppKit
import CoreAudio
import TakkuCore

/// Every second reads which apps are using an audio input (Core Audio process objects: nothing
/// is recorded or listened to) and passes them to `CallWatch`, which decides when to suggest
/// starting or stopping a Meeting. Takku itself is ignored.
@MainActor
final class CallDetector {
    private var watch = CallWatch()
    private var poller: Task<Void, Never>?
    private static let clockOrigin = ContinuousClock.now

    /// `isRecording` is read at every poll; `suggest` is called with what `CallWatch` suggests.
    func start(isRecording: @escaping @MainActor () -> Bool, suggest: @escaping @MainActor (CallWatch.Suggestion) -> Void) {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if AppSettings.suggestCalls {
                    let apps = Self.appsUsingInput()
                    // Counts the time asleep too: a wake-up after a long sleep is a gap, not a call.
                    let elapsed = Self.clockOrigin.duration(to: .now).components
                    let now = TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) * 1e-18
                    if let suggestion = self.watch.update(appsUsingInput: apps, isRecording: isRecording(), now: now) {
                        suggest(suggestion)
                    }
                } else {
                    self.watch = CallWatch()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Listening for "Hey Siri" is not a call.
    private static let ignoredProcesses: Set<String> = ["com.apple.CoreSpeech"]

    /// System processes that capture for an app without being part of it: the app and its name
    /// when it is not running.
    private static let systemProcesses = [
        "com.apple.avconferenced": (bundleID: "com.apple.FaceTime", name: "FaceTime"),
        "com.apple.WebKit.GPU": (bundleID: "com.apple.Safari", name: "Safari"),
    ]

    /// The apps with a process using an audio input, Takku excluded.
    private static func appsUsingInput() -> Set<CallApp> {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var apps: Set<CallApp> = []
        for process in processObjects() where isRunningInput(process) {
            guard let pid = processPID(process), pid != ownPID else { continue }
            let bundleID = bundleID(process)
            if let bundleID, ignoredProcesses.contains(bundleID) { continue }
            apps.insert(app(pid: pid, bundleID: bundleID))
        }
        return apps
    }

    /// The app a process belongs to: a helper (`com.google.Chrome.helper`, Zoom's `us.zoom.CptHost`)
    /// is named after its app, found by bundle identifier or, failing that, among its parent processes.
    private static func app(pid: pid_t, bundleID: String?) -> CallApp {
        if let bundleID, let system = systemProcesses[bundleID] {
            return regularApp(withBundleID: system.bundleID) ?? CallApp(name: system.name, bundleID: system.bundleID)
        }
        if let bundleID {
            for candidate in CallApp.candidateBundleIDs(forAudioProcess: bundleID) {
                if let app = regularApp(withBundleID: candidate) { return app }
            }
        }
        var current = pid
        for _ in 0..<4 {
            guard let parent = parentPID(of: current), parent > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular,
               let name = app.localizedName {
                return CallApp(name: name, bundleID: app.bundleIdentifier)
            }
            current = parent
        }
        let running = NSRunningApplication(processIdentifier: pid)
        return CallApp(
            name: running?.localizedName ?? bundleID ?? String(localized: "another app"),
            bundleID: running?.bundleIdentifier ?? bundleID
        )
    }

    private static func regularApp(withBundleID bundleID: String) -> CallApp? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.activationPolicy == .regular }),
            let name = app.localizedName
        else { return nil }
        return CallApp(name: name, bundleID: bundleID)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    // MARK: - Core Audio

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        return read(kAudioProcessPropertyIsRunningInput, of: process, into: &running) && running != 0
    }

    private static func processPID(_ process: AudioObjectID) -> pid_t? {
        var pid: pid_t = 0
        return read(kAudioProcessPropertyPID, of: process, into: &pid) ? pid : nil
    }

    private static func bundleID(_ process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty
        else { return nil }
        return string
    }

    private static func read<Value>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, into value: inout Value) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}
