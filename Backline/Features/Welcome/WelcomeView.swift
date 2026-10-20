import SwiftUI

/// First launch (spec §12, milestone 10): three steps, over the starter song
/// the store has already made. It can be shown again from the song menu.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let text: String
    }

    private let steps = [
        Step(id: 1, symbol: "rectangle.split.3x1",
             title: "Build the song",
             text: "A song is a row of sections. We've started one for you: Intro, Verse, Chorus, Verse, Chorus, Outro. Tap a section to change its length, groove and feel."),
        Step(id: 2, symbol: "magnifyingglass",
             title: "Pick a groove",
             text: "Change groove lets you search in plain words, like “shuffle” or “half-time”, and hear each one before you choose."),
        Step(id: 3, symbol: "guitars",
             title: "Play along",
             text: "Press Play, or open Play-along for a big screen you can read from across the room. A foot pedal can move between sections so your hands stay on the guitar."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("Welcome to Backline")
                        .font(Theme.condensed(40, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                }
                Text("A drummer for your practice, built for guitarists. Every sound is made inside the app, so anything you export is yours.")
                    .font(Theme.body(17))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 16) {
                        Text("\(step.id)")
                            .font(Theme.condensed(22, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 40, height: 40)
                            .background(Theme.accent, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Label(step.title, systemImage: step.symbol)
                                .font(Theme.condensed(24, weight: .bold))
                            Text(step.text)
                                .font(Theme.body(16))
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .accessibilityElement(children: .combine)
                }
            }

            HStack {
                Text("See this again any time from the song menu.")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Let's go").frame(minWidth: 140)
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }
}
