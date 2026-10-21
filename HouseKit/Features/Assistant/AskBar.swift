import SwiftUI

/// "Tell HouseKit what you want": type or hold the mic and speak. Shows the
/// words as they're heard, a few suggestions to start from, and what changed,
/// with Undo.
struct AskBar: View {
    @Environment(Assistant.self) private var assistant
    /// The section on screen, for requests like "this section".
    let currentSectionID: UUID?
    /// Play-along: no suggestion chips, so the screen stays readable.
    var compact = false
    /// Told when typing starts and stops, so the screen can keep still under
    /// the keyboard.
    var onTyping: ((Bool) -> Void)? = nil
    @State private var text = ""
    @FocusState private var typing: Bool
    /// Play-along types in a pop-up, so the keyboard doesn't squash the screen.
    @State private var typingInPopup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MicButton(currentSectionID: currentSectionID, size: compact ? 56 : 48)
                    .tutorialAnchor("mic")
                field
                if !compact {
                    Button {
                        send(text)
                    } label: {
                        Text("Do it").frame(minWidth: 60)
                    }
                    .buttonStyle(ChipButtonStyle(prominent: !text.isEmpty))
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || assistant.phase != .idle)
                }
            }
            if let reply = assistant.reply {
                ReplyCard(reply: reply)
            } else if !compact, assistant.phase == .idle, text.isEmpty {
                suggestions
            }
        }
    }

    private var field: some View {
        ZStack(alignment: .leading) {
            if assistant.phase == .listening {
                Text(assistant.speech.transcript.isEmpty ? "Listening… let go when you're done" : assistant.speech.transcript)
                    .foregroundStyle(assistant.speech.transcript.isEmpty ? Theme.textMuted : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .accessibilityAddTraits(.updatesFrequently)
            } else if assistant.phase == .thinking {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.accent)
                    Text("Working on it…").foregroundStyle(Theme.textMuted)
                }
            } else if compact {
                Button {
                    typingInPopup = true
                } label: {
                    Text("Hold the mic and speak, or tap here to type")
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Type a request")
            } else {
                TextField("Tell HouseKit what you want: “more swing in the chorus”, “punchier”, “add a bridge”…",
                          text: $text)
                    .focused($typing)
                    .onChange(of: typing) { _, now in onTyping?(now) }
                    .submitLabel(.go)
                    .onSubmit { send(text) }
                    .autocorrectionDisabled()
            }
        }
        .font(Theme.body(16))
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .alert("Tell HouseKit", isPresented: $typingInPopup) {
            TextField("“next section”, “more swing”, “loop this”…", text: $text)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { text = "" }
            Button("Do it") { send(text) }
        }
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Try")
                    .font(Theme.condensed(13, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textMuted)
                ForEach(Assistant.suggestions, id: \.self) { suggestion in
                    Button(suggestion) { send(suggestion) }
                        .buttonStyle(ChipButtonStyle())
                }
            }
        }
    }

    private func send(_ request: String) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        typing = false
        text = ""
        assistant.submit(trimmed, currentSectionID: currentSectionID)
    }
}

/// Hold to talk; let go to apply. VoiceOver users double-tap to start and
/// again to finish.
struct MicButton: View {
    @Environment(Assistant.self) private var assistant
    let currentSectionID: UUID?
    var size: CGFloat = 48
    @State private var held = false

    var body: some View {
        let listening = assistant.phase == .listening
        Image(systemName: listening ? "waveform" : "mic.fill")
            .font(.system(size: size * 0.4, weight: .bold))
            .symbolEffect(.variableColor.iterative, isActive: listening)
            .foregroundStyle(listening ? Theme.onAccent : Theme.text)
            .frame(width: size, height: size)
            .background(listening ? Theme.accent : Theme.surfaceHi, in: Circle())
            .contentShape(Circle())
            // Down starts listening, up finishes: a drag that never needs to move.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !held else { return }
                        held = true
                        assistant.startListening()
                    }
                    .onEnded { _ in
                        held = false
                        assistant.stopListening(currentSectionID: currentSectionID)
                    }
            )
            .disabled(assistant.phase == .thinking)
            .accessibilityElement()
            .accessibilityLabel(listening ? "Stop listening" : "Speak a request")
            .accessibilityHint("Hold and speak, then let go. For example: more swing in the chorus.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if listening {
                    assistant.stopListening(currentSectionID: currentSectionID)
                } else {
                    assistant.startListening()
                }
            }
    }
}

/// What the request changed, anything it couldn't do, and Undo.
private struct ReplyCard: View {
    @Environment(Assistant.self) private var assistant
    let reply: Assistant.Reply

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !reply.request.isEmpty {
                    Text("“\(reply.request)”")
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                ForEach(reply.done, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle.fill")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .labelStyle(TintedIconLabel(tint: Theme.ok))
                }
                ForEach(reply.problems, id: \.self) { line in
                    Label(line, systemImage: "info.circle")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if reply.canUndo {
                Button("Undo") { assistant.undo() }
                    .buttonStyle(ChipButtonStyle())
            }
            Button {
                assistant.dismissReply()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ChipButtonStyle())
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

/// A label whose icon has its own colour.
private struct TintedIconLabel: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
