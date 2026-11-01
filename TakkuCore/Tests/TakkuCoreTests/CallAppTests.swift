import Testing
import TakkuCore

@Suite("The app behind a process using the microphone")
struct CallAppTests {
    @Test("a helper is tried as itself, then as each shorter bundle identifier")
    func prefixes() {
        #expect(CallApp.candidateBundleIDs(forAudioProcess: "com.google.Chrome.helper")
            == ["com.google.Chrome.helper", "com.google.Chrome", "com.google"])
    }

    @Test("Zoom's and Firefox's helpers lead to their app first")
    func knownHelpers() {
        #expect(CallApp.candidateBundleIDs(forAudioProcess: "us.zoom.CptHost").first == "us.zoom.xos")
        #expect(CallApp.candidateBundleIDs(forAudioProcess: "org.mozilla.plugincontainer").first == "org.mozilla.firefox")
    }

    @Test("call apps are told from browsers, chat apps and the others")
    func kinds() {
        #expect(CallApp(name: "zoom.us", bundleID: "us.zoom.xos").kind == .callApp)
        #expect(CallApp(name: "Google Chrome", bundleID: "com.google.Chrome").kind == .mayBeCall)
        #expect(CallApp(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp").kind == .mayBeCall)
        #expect(CallApp(name: "Dettatura", bundleID: "com.example.dictation").kind == nil)
        #expect(CallApp(name: "CptHost", bundleID: nil).kind == nil)
    }
}
