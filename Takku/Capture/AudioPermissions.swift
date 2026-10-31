import AVFoundation
import AppKit
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "permissions")

/// The microphone and system audio permissions, asked from the welcome window so that macOS does
/// not interrupt the first call with its prompts.
@MainActor
enum AudioPermissions {
    static var microphoneAllowed: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// The system audio has no request of its own: macOS asks when a process tap starts, so one
    /// runs for a moment, recording nothing. Whether it was allowed cannot be read.
    static func request() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        let capture = SystemAudioCapture()
        do {
            try capture.start { _, _ in }
            try? await Task.sleep(for: .seconds(1))
            capture.stop()
        } catch {
            logger.error("System audio tap for the permission failed: \(error, privacy: .public)")
        }
    }

    /// The prompts belong to another app of macOS: when the last one closes, the focus goes back
    /// to the app that was in front before Takku, and `window` would stay behind it (Takku has no
    /// Dock icon to come back with). The system audio prompt can outlive `request()`, so this
    /// waits, up to two minutes, until the app in front is no longer one without a Dock icon.
    static func bringBack(_ window: NSWindow?) async {
        for _ in 0..<480 {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front != .current,
                  front.activationPolicy != .regular
            else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        NSApplication.shared.activate()
        // In front even if macOS turns the activation down; the next click then activates Takku.
        window?.orderFrontRegardless()
        window?.makeKey()
    }
}
