import Foundation
import Observation
import SwiftUI

@Observable
final class SpeakerNamingDraft {
    let takkuID: UUID
    let meetingTitle: String
    let speakers: [Int]
    let participants: [String]
    var names: [Int: String]
    var error: String?

    init(takkuID: UUID, meetingTitle: String, speakers: [Int], names: [Int: String], participants: [String]) {
        self.takkuID = takkuID
        self.meetingTitle = meetingTitle
        self.speakers = speakers
        self.names = names
        self.participants = participants
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
                }

                ForEach(draft.speakers, id: \.self) { speaker in
                    HStack(spacing: 10) {
                        Text("Speaker \(speaker)")
                            .frame(width: 80, alignment: .leading)
                        TextField("Name", text: nameBinding(for: speaker, in: draft))
                            .frame(width: 220)
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

                if let error = draft.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
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
            .frame(minWidth: 500)
        }
    }

    private func nameBinding(for speaker: Int, in draft: SpeakerNamingDraft) -> Binding<String> {
        Binding(
            get: { draft.names[speaker] ?? "" },
            set: { draft.names[speaker] = $0 }
        )
    }

    private func close() {
        controller.speakerNaming = nil
        dismiss()
    }
}
