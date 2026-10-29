import Foundation
import Observation
import SwiftUI
import TakkuCore

@MainActor
@Observable
final class SpeakerNamingDraft {
    let takkuID: UUID
    let meetingTitle: String
    let speakers: [Int]
    let participants: [String]
    /// What each Speaker says, to recognise them: quotes, and their voice while the audio exists.
    let samples: [Int: [SpeakerSample]]
    let player: SpeakerSamplePlayer?
    var names: [Int: String]
    var error: String?

    init(
        takkuID: UUID, meetingTitle: String, speakers: [Int], names: [Int: String], participants: [String],
        samples: [Int: [SpeakerSample]], player: SpeakerSamplePlayer?
    ) {
        self.takkuID = takkuID
        self.meetingTitle = meetingTitle
        self.speakers = speakers
        self.names = names
        // Alphabetical, to find a name quickly; the note keeps the calendar's order.
        self.participants = participants.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.samples = samples
        self.player = player
    }

    /// The sample whose quote is shown: the one played last, otherwise the longest.
    func shownSample(of speaker: Int) -> SpeakerSample? {
        guard let samples = samples[speaker], !samples.isEmpty else { return nil }
        let index = player?.selected[speaker] ?? 0
        return samples[min(index, samples.count - 1)]
    }
}

/// Names the Speakers found in a Transcript, with the calendar participants as suggestions.
struct SpeakerNamesView: View {
    static let windowID = "speaker-names"

    let controller: MeetingController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let draft = controller.speakerNaming {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name speakers").font(.headline)
                    Text(draft.meetingTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Fixed, like the error below: the window is as wide as the Speaker rows.
                        .frame(width: 400, alignment: .leading)
                }

                ForEach(draft.speakers, id: \.self) { speaker in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Speaker \(speaker)")
                            .frame(width: 80, alignment: .leading)
                        if let player = draft.player {
                            Button {
                                player.toggle(speaker, samples: draft.samples[speaker] ?? [])
                            } label: {
                                Image(systemName: player.playing == speaker ? "stop.fill" : "play.fill")
                                    .frame(width: 14)
                            }
                            .buttonStyle(.borderless)
                            .disabled(draft.samples[speaker]?.isEmpty ?? true)
                            .help("Play a few seconds of this voice. Play again for another passage.")
                            .accessibilityLabel(player.playing == speaker ? "Stop" : "Play Speaker \(speaker)")
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Name", text: nameBinding(for: speaker, in: draft))
                            if let sample = draft.shownSample(of: speaker) {
                                Text(verbatim: "[\(elapsedLabel(sample.start))] “\(sample.quote)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(width: 260)
                        if !draft.participants.isEmpty {
                            Menu("Participants") {
                                ForEach(draft.participants, id: \.self) { participant in
                                    Button(participant) { draft.names[speaker] = participant }
                                }
                            }
                        }
                    }
                }

                if !draft.participants.isEmpty {
                    Text("Choose an invited participant or enter a name. Empty fields stay unnamed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = draft.error ?? draft.player?.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 400, alignment: .leading)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { close() }
                    Button("Save and Regenerate") {
                        guard controller.processor.saveSpeakerNames(
                            draft.names, for: draft.takkuID,
                            templateName: controller.templateName, profile: AppSettings.activeProviderProfile
                        ) else {
                            draft.error = controller.processor.lastError
                            return
                        }
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            // The window takes the width of the Speaker rows, so the buttons end under the last column.
            .fixedSize()
            .onDisappear { draft.player?.stop() }
        }
    }

    private func nameBinding(for speaker: Int, in draft: SpeakerNamingDraft) -> Binding<String> {
        Binding(
            get: { draft.names[speaker] ?? "" },
            set: { draft.names[speaker] = $0 }
        )
    }

    private func close() {
        controller.speakerNaming?.player?.stop()
        controller.speakerNaming = nil
        dismiss()
    }
}
