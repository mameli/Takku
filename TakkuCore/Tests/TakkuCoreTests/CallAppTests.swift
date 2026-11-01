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

    @Test("call apps are told from browsers and other apps")
    func callApps() {
        #expect(CallApp(name: "zoom.us", bundleID: "us.zoom.xos").isCallApp)
        #expect(!CallApp(name: "Google Chrome", bundleID: "com.google.Chrome").isCallApp)
        #expect(!CallApp(name: "CptHost", bundleID: nil).isCallApp)
    }
}
