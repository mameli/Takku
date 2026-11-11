/// Whether Takku's notifications reach the user, as Settings and the welcome window show it.
///
/// macOS asks the user only once: after *Don't Allow*, or with Takku turned off in System Settings →
/// Notifications, asking again shows nothing, and only System Settings can turn them back on.
public enum NotificationAccess: Equatable, Sendable {
    /// Never asked: asking now shows macOS's prompt.
    case notAsked
    case allowed
    /// Not allowed, or allowed with the alert style set to None: nothing shows on screen.
    case off

    /// - Parameters:
    ///   - isDetermined: the user answered the prompt (`authorizationStatus` other than `.notDetermined`).
    ///   - isAuthorized: `authorizationStatus` is `.authorized` or `.provisional`.
    ///   - showsAlerts: the alert style is not None.
    public init(isDetermined: Bool, isAuthorized: Bool, showsAlerts: Bool) {
        if !isDetermined {
            self = .notAsked
        } else if isAuthorized && showsAlerts {
            self = .allowed
        } else {
            self = .off
        }
    }
}
