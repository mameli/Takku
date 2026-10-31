import AppKit
import SwiftUI

/// A card under the System Settings window with Takku as a row to drag into a Privacy list, as
/// macOS suggests for apps that are not in it yet ("+" does the same with a file dialog). It
/// follows the window, steps aside while another app is in front and closes with System Settings.
/// It finds the window through the window server: no Accessibility permission is needed.
@MainActor
final class SettingsDragCard {
    static let shared = SettingsDragCard()

    private var panel: NSPanel?
    private var tracking: Task<Void, Never>?
    private static let settingsBundleID = "com.apple.systempreferences"
    fileprivate static let width: CGFloat = 360

    /// Opens `pane` and shows the card once its window is on screen. `list` names the list in the
    /// pane to drag Takku into.
    func show(for pane: PrivacyPane, list: String) {
        close()
        pane.open()
        let content = NSHostingView(rootView: CardView(list: list) { [weak self] in self?.close() })
        // As tall as the instruction needs: the name of a list can take two lines.
        let size = NSSize(width: Self.width, height: content.fittingSize.height)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        self.panel = panel
        tracking = Task { [weak self] in
            // System Settings may take a few seconds to launch and open the pane.
            var missing = 0
            while !Task.isCancelled, let self {
                if let window = Self.settingsWindow() {
                    missing = 0
                    self.follow(window)
                } else {
                    missing += 1
                    panel.orderOut(nil)
                    if missing > 50 { return self.close() }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func close() {
        tracking?.cancel()
        tracking = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func follow(_ settings: NSRect) {
        guard let panel else { return }
        // Only over System Settings or Takku's own windows, as part of them.
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier == Self.settingsBundleID || front == .current else {
            return panel.orderOut(nil)
        }
        let visible = NSScreen.screens.first { $0.frame.intersects(settings) }?.visibleFrame ?? settings
        // Centred under the pane, right of the sidebar; inside its empty lower part when there is
        // no room below.
        let sidebar: CGFloat = 230
        let x = settings.minX + sidebar + (settings.width - sidebar - Self.width) / 2
        let below = settings.minY - panel.frame.height - 10
        let y = below >= visible.minY ? below : settings.minY + 20
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        if !panel.isVisible { panel.orderFront(nil) }
    }

    /// The frame of the System Settings window, in AppKit screen coordinates; `nil` when it has none on screen.
    private static func settingsWindow() -> NSRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        let frames = windows.compactMap { window -> CGRect? in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        // The window server counts from the top left of the main display, AppKit from its bottom left.
        guard let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }),
              let mainHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        return NSRect(x: largest.minX, y: mainHeight - largest.maxY, width: largest.width, height: largest.height)
    }
}

private struct CardView: View {
    let list: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up").foregroundStyle(.tint)
                Text("Drag Takku to \(list) above")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
            }
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text(verbatim: "Takku")
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(AppDragSource())
        }
        .padding(12)
        .frame(width: SettingsDragCard.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The row's drag: Takku.app itself, which is what the Privacy lists take.
private struct AppDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView, NSDraggingSource {
        // The panel never becomes active: the first click must already start the drag.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            let location = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(
                NSRect(x: location.x - 16, y: location.y - 16, width: 32, height: 32), contents: NSApp.applicationIconImage
            )
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}
