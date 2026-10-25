import Foundation

enum CaptureError: LocalizedError {
    case coreAudio(step: String, status: OSStatus)
    case unsupportedFormat(String)
    case microphone(format: String, underlying: Error)
    /// An imported file with no audio macOS can decode (not audio or video, or a video without sound).
    case unreadableFile(String)
    case noAudio(String)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status):
            String(localized: "Core Audio could not complete \"\(step)\" (code \(status)).")
        case .unsupportedFormat(let format):
            String(localized: "Unsupported audio format: \(format).")
        case .microphone(let format, let underlying):
            String(localized: "The microphone does not start (\(format)): \(underlying.localizedDescription)")
        case .unreadableFile(let name):
            String(localized: "Cannot read the audio of \(name).")
        case .noAudio(let name):
            String(localized: "\(name) contains no audio.")
        }
    }
}

func checkCoreAudio(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw CaptureError.coreAudio(step: step, status: status) }
}
