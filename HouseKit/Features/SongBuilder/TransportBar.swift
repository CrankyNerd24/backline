import SwiftUI

/// Play/stop, loop the selected section, position, count-in, and (later)
/// practice speed and play-along mode.
struct TransportBar: View {
    @Environment(SongStore.self) private var store
    @Environment(EngineController.self) private var engine
    @Environment(PedalController.self) private var pedals
    @Environment(Assistant.self) private var assistant
    @Environment(Tutorial.self) private var tutorial
    let selection: UUID?
    @State private var playingAlong = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                engine.isPlaying ? engine.stop() : engine.play(from: selection)
            } label: {
                Image(systemName: engine.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 64)
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .disabled(store.song.sections.isEmpty)
            .accessibilityLabel(engine.isPlaying ? "Stop" : "Play from \(selectedName ?? "the start")")
            .tutorialAnchor("play")

            loopButton

            Text(positionText)
                .font(Theme.condensed(22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
                .frame(minWidth: 140, alignment: .leading)
                .padding(.leading, 8)

            Spacer(minLength: 12)

            countInMenu
            speedMenu
            Button {
                playingAlong = true
            } label: {
                Label("Play-along mode", systemImage: "music.mic")
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .tutorialAnchor("playAlong")
            .disabled(store.song.sections.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.bgDeep)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        .fullScreenCover(isPresented: $playingAlong) {
            PlayAlongView(startingAt: selection)
                .environment(store)
                .environment(engine)
                .environment(pedals)
                .environment(assistant)
                .environment(tutorial)
        }
    }

    private var speedMenu: some View {
        @Bindable var engine = engine
        return Menu {
            ForEach(Array(stride(from: 50, through: 120, by: 10)), id: \.self) { percent in
                Button {
                    engine.speed = Double(percent) / 100
                } label: {
                    if Int((engine.speed * 100).rounded()) == percent {
                        Label("\(percent)%", systemImage: "checkmark")
                    } else {
                        Text("\(percent)%")
                    }
                }
            }
        } label: {
            Label("Speed \(Int((engine.speed * 100).rounded()))%", systemImage: "gauge.with.dots.needle.50percent")
        }
        .buttonStyle(ChipButtonStyle(prominent: engine.speed != 1.0))
        .accessibilityLabel("Practice speed \(Int((engine.speed * 100).rounded())) percent")
    }

    private var selectedName: String? {
        selection.flatMap { id in store.song.sections.first { $0.id == id }?.name }
    }

    private var loopButton: some View {
        let looping = engine.loopingSectionID.flatMap { id in store.song.sections.first { $0.id == id } }
        return Button {
            engine.setLoop(looping == nil ? selection : nil)
        } label: {
            Label(looping.map { "Looping \($0.name)" } ?? "Loop \(selectedName ?? "section")", systemImage: "repeat")
                .lineLimit(1)
        }
        .buttonStyle(ChipButtonStyle(prominent: looping != nil))
        .disabled(selection == nil && looping == nil)
        .accessibilityHint(looping == nil ? "Repeats the selected section when playback reaches its end" : "Stops looping")
    }

    private var countInMenu: some View {
        Menu {
            ForEach(0...2, id: \.self) { bars in
                Button {
                    store.song.countInBars = bars
                } label: {
                    let text = bars == 0 ? "No count-in" : bars == 1 ? "1 bar" : "\(bars) bars"
                    if bars == store.song.countInBars {
                        Label(text, systemImage: "checkmark")
                    } else {
                        Text(text)
                    }
                }
            }
        } label: {
            Label(store.song.countInBars == 0 ? "No count-in" : "Count-in \(store.song.countInBars)",
                  systemImage: "metronome")
        }
        .buttonStyle(ChipButtonStyle())
    }

    private var positionText: String {
        guard let position = engine.position else { return "Stopped" }
        if position.isCountIn { return "Count-in \(position.barInSection + 1)" }
        let barSeconds = Double(position.beatsInBar) * 60 / engine.playbackBPM
        let seconds = store.song.seconds(toBar: position.songBar, bpm: engine.playbackBPM) + position.barPhase * barSeconds
        return "Bar \(position.songBar + 1) · \(seconds.minutesSeconds)"
    }
}
