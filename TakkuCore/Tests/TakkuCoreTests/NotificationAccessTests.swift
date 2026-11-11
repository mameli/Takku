import Testing
import TakkuCore

@Suite("Whether Takku's notifications reach the user")
struct NotificationAccessTests {
    @Test("never asked, whatever else macOS says: the prompt can still be shown")
    func notAsked() {
        #expect(NotificationAccess(isDetermined: false, isAuthorized: false, showsAlerts: false) == .notAsked)
        #expect(NotificationAccess(isDetermined: false, isAuthorized: false, showsAlerts: true) == .notAsked)
    }

    @Test("allowed with banners or alerts")
    func allowed() {
        #expect(NotificationAccess(isDetermined: true, isAuthorized: true, showsAlerts: true) == .allowed)
    }

    @Test("Don't Allow, Takku turned off, or allowed with the alert style None: off, only System Settings brings them back")
    func off() {
        #expect(NotificationAccess(isDetermined: true, isAuthorized: false, showsAlerts: true) == .off)
        #expect(NotificationAccess(isDetermined: true, isAuthorized: false, showsAlerts: false) == .off)
        #expect(NotificationAccess(isDetermined: true, isAuthorized: true, showsAlerts: false) == .off)
    }
}
