import SwiftUI

/// The ⋯ at the end of a row with several actions, as in Finder and Notes: the row shows what
/// it is, the menu what can be done with it.
struct MoreMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        // A borderless button, not a borderless menu: the same size, colour and place as the
        // IconButtons in the rows next to it.
        Menu(content: content) {
            RowIcon(systemImage: "ellipsis.circle")
                .accessibilityLabel(Text("More"))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("More"))
    }
}

/// A small icon button with no border, its name as tooltip and for VoiceOver.
struct IconButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RowIcon(systemImage: systemImage)
                .accessibilityLabel(Text(title))
        }
        .buttonStyle(.borderless)
        .help(Text(title))
    }
}

/// The icon at the end of a row: one size and box for all, so a column of them lines up.
struct RowIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.body)
            // Primary, as a menu draws its label whatever colour it is given.
            .foregroundStyle(.primary)
            .frame(width: 20, height: 20)
    }
}
