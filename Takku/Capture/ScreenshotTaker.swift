import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Takes a Screenshot: the frontmost window, at its native resolution, as JPEG; a window in full
/// screen fills the display, so it is the whole screen without the menu bar. Without a window
/// (the desktop, an app with none open) it is the whole main display. Needs the Screen Recording
/// permission, which the system audio does not give.
enum ScreenshotTaker {
    enum Failure: LocalizedError {
        case noDisplay
        case encoding

        var errorDescription: String? {
            switch self {
            case .noDisplay: String(localized: "No display to take it from.")
            case .encoding: String(localized: "The image could not be saved as JPEG.")
            }
        }
    }

    /// Whether Takku may take Screenshots. The first time it asks; macOS applies a permission
    /// given then only when Takku is reopened.
    static func isAllowed() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    static func jpeg() async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let front = frontmostWindow()
        let filter: SCContentFilter
        if let front, let window = content.windows.first(where: { $0.windowID == front.id }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            let displayID = front.flatMap { display(at: CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
                ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                throw Failure.noDisplay
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try jpegData(image)
    }

    /// The frontmost app's front window; `nil` without one. The window list is in front-to-back
    /// order and gives bounds without the permission. Skipped: invisible windows, like the title
    /// bar of a window in full screen, a separate window shown only under the pointer, and strips
    /// too small to be what the user is looking at, like that title bar once shown.
    private static func frontmostWindow() -> (id: CGWindowID, bounds: CGRect)? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]]
        else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID] as? pid_t) == pid,
                  (window[kCGWindowLayer] as? Int) == 0,
                  (window[kCGWindowAlpha] as? Double ?? 0) > 0,
                  let id = window[kCGWindowNumber] as? CGWindowID,
                  let boundsInfo = window[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 100, bounds.height >= 100
            else { continue }
            return (id, bounds)
        }
        return nil
    }

    private static func display(at point: CGPoint) -> CGDirectDisplayID? {
        var displayID = CGDirectDisplayID()
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success, count > 0 else { return nil }
        return displayID
    }

    private static func jpegData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encoding
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        return data as Data
    }
}
