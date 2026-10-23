import Foundation

/// Carries out assistant steps on the song, its kit and playback, and says
/// in plain words what changed. Song and kit changes land as one edit, so a
/// single Undo takes the whole request back.
struct AssistantApplier {
    let store: SongStore
    let library: GrooveLibrary
    let kits: KitLibrary
    let engine: EngineController
    let purchases: Purchases
    /// The section on screen: selected in the builder, cued or playing in Play-along.
    let currentSectionID: UUID?

    struct Outcome {
        var done: [String] = []
        var skipped: [String] = []
        var songChanged = false
    }

    func apply(_ steps: [AssistantStep]) -> Outcome {
        var outcome = Outcome()
        var song = store.song
        var playback: [AssistantStep] = []
        for step in steps {
            switch step.action {
            case .play, .stop, .nextSection, .previousSection, .restartSection, .fillNow, .bigEnding, .loop:
                playback.append(step) // after the song changes are in
            default:
                apply(step, to: &song, outcome: &outcome)
            }
        }
        if song != store.song {
            store.song = song
            engine.load(song) // so playback below hears the change
            outcome.songChanged = true
        }
        for step in playback { play(step, song: song, outcome: &outcome) }
        return outcome
    }

    // MARK: Song and kit

    private func apply(_ step: AssistantStep, to song: inout Song, outcome: inout Outcome) {
        switch step.action {
        case .swing, .busy, .intensity, .human:
            let targets = indices(step.target, in: song)
            guard !targets.isEmpty else { return outcome.skipped.append(noSection(step.target)) }
            let amount = step.amount ?? 0.25
            var applied: [Int] = []
            for i in targets {
                if step.action == .swing && !song.sections[i].timeSignature.allowsSwing { continue }
                let feel = song.sections[i].feel
                let next = { (old: Double) in min(max(old + amount, 0), 1) }
                switch step.action {
                case .swing: song.sections[i].feel.swing = next(feel.swing)
                case .busy: song.sections[i].feel.busy = next(feel.busy)
                case .intensity: song.sections[i].feel.intensity = next(feel.intensity)
                default: song.sections[i].feel.human = next(feel.human)
                }
                applied.append(i)
            }
            guard let first = applied.first else {
                return outcome.skipped.append("Swing doesn't apply in 6/8 or 12/8, which already swing")
            }
            let words: (String, String) = switch step.action {
            case .swing: ("More swing", "Straighter")
            case .busy: ("Busier", "Simpler")
            case .intensity: ("Harder", "Softer")
            default: ("Looser, more human", "Tighter")
            }
            let value: Double = switch step.action {
            case .swing: song.sections[first].feel.swing
            case .busy: song.sections[first].feel.busy
            case .intensity: song.sections[first].feel.intensity
            default: song.sections[first].feel.human
            }
            outcome.done.append("\(amount >= 0 ? words.0 : words.1) on \(describe(applied, in: song)) (now \(percent(value)))")

        case .halfTime, .doubleTime, .normalTime:
            let time: TimeFeel = step.action == .halfTime ? .half : step.action == .doubleTime ? .double : .normal
            let targets = indices(step.target, in: song).filter {
                time == .normal || song.sections[$0].timeSignature.allowsTimeFeel
            }
            guard !targets.isEmpty else {
                return outcome.skipped.append("Half and double time work in 4/4 and 12/8 only")
            }
            for i in targets { song.sections[i].time = time }
            outcome.done.append("\(time.label) time on \(describe(targets, in: song))")

        case .onRide, .onHiHat, .onCrash:
            let cymbals: CymbalChoice = step.action == .onRide ? .ride : step.action == .onHiHat ? .hihat : .crash
            let targets = indices(step.target, in: song)
            guard !targets.isEmpty else { return outcome.skipped.append(noSection(step.target)) }
            for i in targets { song.sections[i].cymbals = cymbals }
            outcome.done.append("\(describe(targets, in: song).capitalizedFirst) on the \(cymbals.label.lowercased())")

        case .fill:
            let size: FillSize = switch (step.value ?? "small").lowercased() {
            case "none", "no", "off": .none
            case "big", "large": .big
            default: .small
            }
            let targets = indices(step.target, in: song)
            guard !targets.isEmpty else { return outcome.skipped.append(noSection(step.target)) }
            for i in targets { song.sections[i].fillIntoNext = size }
            outcome.done.append(size == .none ? "No fills out of \(describe(targets, in: song))"
                                : "\(size.label) fills out of \(describe(targets, in: song))")

        case .punch, .room:
            var kit = song.kitOverride ?? kits.kit(song.kitID)
            let amount = (step.amount ?? 0.25)
            if step.action == .punch {
                kit.punch = min(max(kit.punch + amount, 0), 1)
                outcome.done.append("\(amount >= 0 ? "Punchier" : "More natural") kit (punch \(percent(kit.punch)))")
            } else {
                kit.room = min(max(kit.room + amount, 0), 1)
                outcome.done.append("\(amount >= 0 ? "Bigger room" : "Drier") (room \(percent(kit.room)))")
            }
            song.kitOverride = kit

        case .brightness, .pieceVolume:
            var kit = song.kitOverride ?? kits.kit(song.kitID)
            let pieces = Self.pieces(step.value)
            let amount = step.amount ?? 0.25
            for piece in pieces {
                var voice = kit.voice(piece)
                if step.action == .brightness {
                    voice.tone = min(max(voice.tone + amount, 0), 1)
                } else {
                    voice.volumeDB = min(max(voice.volumeDB + amount * 12, -24), 6)
                }
                kit.voices[piece] = voice
            }
            song.kitOverride = kit
            let what = Self.piecesName(step.value)
            if step.action == .brightness {
                outcome.done.append("\(amount >= 0 ? "Brighter" : "Darker") \(what)")
            } else {
                outcome.done.append("\(what.capitalizedFirst) \(amount >= 0 ? "louder" : "quieter") by \(Int(abs(amount * 12).rounded())) dB")
            }

        case .useKit:
            let wanted = (step.value ?? "").lowercased()
            guard !wanted.isEmpty,
                  let kit = kits.all.first(where: { $0.name.lowercased() == wanted })
                  ?? kits.all.first(where: { $0.name.lowercased().contains(wanted) || wanted.contains($0.name.lowercased()) })
            else {
                return outcome.skipped.append("No kit called “\(step.value ?? "")”. Kits: \(kits.all.map(\.name).joined(separator: ", "))")
            }
            guard purchases.allows(kit, in: kits) else {
                return outcome.skipped.append("The \(kit.name) is in HouseKit Full. The free kits are the Garage Kit and Big Rusty.")
            }
            song.kitID = kit.id
            song.kitOverride = nil
            outcome.done.append("Switched to the \(kit.name)")

        case .setTempo, .changeTempo:
            let old = song.bpm
            let target = step.action == .setTempo ? (step.amount ?? old) : old + (step.amount ?? 8)
            song.bpm = min(max(target.rounded(), Song.bpmRange.lowerBound), Song.bpmRange.upperBound)
            outcome.done.append("Tempo \(Int(old)) → \(Int(song.bpm)) BPM")

        case .groove:
            changeGroove(step, in: &song, outcome: &outcome)

        case .addSection:
            addSection(step, to: &song, outcome: &outcome)

        case .removeSection:
            guard step.target != nil else { return outcome.skipped.append("Say which section to remove") }
            let targets = indices(step.target, in: song)
            guard !targets.isEmpty else { return outcome.skipped.append(noSection(step.target)) }
            let names = describe(targets, in: song)
            for i in targets.sorted(by: >) { song.sections.remove(at: i) }
            outcome.done.append("Removed \(names)")

        case .setBars:
            let bars = Int((step.amount ?? 8).rounded())
            let targets = indices(step.target ?? "this", in: song)
            guard !targets.isEmpty else { return outcome.skipped.append(noSection(step.target)) }
            let clamped = min(max(bars, Section.barRange.lowerBound), Section.barRange.upperBound)
            for i in targets { song.sections[i].bars = clamped }
            outcome.done.append("\(describe(targets, in: song).capitalizedFirst): \(clamped) bars")

        case .changeBars:
            let change = Int((step.amount ?? 0).rounded())
            let targets = indices(step.target ?? "this", in: song)
            guard !targets.isEmpty else { return outcome.skipped.append(noSection(step.target)) }
            guard change != 0 else { return outcome.skipped.append("How many bars? Try “add 4 bars to the chorus”.") }
            for i in targets {
                song.sections[i].bars = min(max(song.sections[i].bars + change, Section.barRange.lowerBound),
                                            Section.barRange.upperBound)
            }
            let lengths = Set(targets.map { song.sections[$0].bars })
            let now = lengths.count == 1 ? " (now \(lengths.first!) bars)" : ""
            outcome.done.append("\(describe(targets, in: song).capitalizedFirst): \(change > 0 ? "+" : "−")\(abs(change)) "
                                + "\(abs(change) == 1 ? "bar" : "bars")\(now)")

        case .repeatUntilStep:
            let on = (step.amount ?? 1) >= 0.5
            let targets = indices(step.target ?? "this", in: song)
            guard !targets.isEmpty else { return outcome.skipped.append(noSection(step.target)) }
            for i in targets { song.sections[i].repeatUntilStep = on }
            outcome.done.append(on ? "\(describe(targets, in: song).capitalizedFirst) repeats until you step"
                                : "\(describe(targets, in: song).capitalizedFirst) plays its bars and moves on")

        case .countIn:
            let bars = min(max(Int((step.amount ?? 1).rounded()), 0), 2)
            song.countInBars = bars
            outcome.done.append(bars == 0 ? "No count-in" : "Count-in: \(bars) \(bars == 1 ? "bar" : "bars")")

        case .play, .stop, .nextSection, .previousSection, .restartSection, .fillNow, .bigEnding, .loop:
            break // handled after the song changes
        }
    }

    private func changeGroove(_ step: AssistantStep, in song: inout Song, outcome: inout Outcome) {
        let targets = indices(step.target, in: song)
        guard !targets.isEmpty else { return outcome.skipped.append(noSection(step.target)) }
        let words = (step.value ?? "").lowercased()
        let different = words.isEmpty || ["different", "another", "something else", "next", "new"].contains { words.contains($0) }
        let style = Self.style(in: words)
        if let style, !purchases.allows(style: style) {
            return outcome.skipped.append("\(style) grooves are in HouseKit Full. The free styles are Rock, Blues & Shuffle, Pop and Ballad.")
        }
        var changed: [Int] = []
        var chosen: Groove?
        for i in targets {
            let section = song.sections[i]
            let current = library.groove(section.grooveID)
            let meter = section.timeSignature
            var candidates: [Groove]
            if different && style == nil {
                candidates = library.search("", style: current.style, meter: meter).filter { $0.id != current.id }
            } else if let style {
                candidates = library.search("", style: style, meter: meter)
                if candidates.isEmpty { candidates = library.search("", style: style) } // another time signature
            } else {
                candidates = library.search(words, meter: meter)
                if candidates.isEmpty { candidates = library.search(words) }
            }
            candidates = candidates.filter { purchases.allows($0) }
            guard !candidates.isEmpty else { continue }
            // Keep a section that already fits; otherwise give choruses and
            // solos the second match so the song keeps some contrast.
            if !different, candidates.contains(where: { $0.id == current.id }) { continue }
            let lift: Set<SectionKind> = [.chorus, .solo, .bridge]
            let groove = candidates[lift.contains(section.kind) ? min(1, candidates.count - 1) : 0]
            song.sections[i].grooveID = groove.id
            song.sections[i].patternOverride = nil
            song.sections[i].cymbals = groove.naturalCymbals
            song.sections[i].timeSignature = groove.timeSignature
            if !groove.timeSignature.allowsTimeFeel { song.sections[i].time = .normal }
            changed.append(i)
            chosen = groove
        }
        guard let chosen else {
            return outcome.skipped.append(words.isEmpty ? "No other grooves to switch to"
                                          : "No grooves match “\(step.value ?? "")”, or they're already in use")
        }
        let name = changed.count == 1 ? "\(chosen.style) › \(chosen.name)" : "\(chosen.style) grooves"
        outcome.done.append("\(describe(changed, in: song).capitalizedFirst): \(name)")
    }

    private func addSection(_ step: AssistantStep, to song: inout Song, outcome: inout Outcome) {
        guard let kind = Self.kind(in: (step.value ?? "").lowercased()) else {
            return outcome.skipped.append("Say what kind of section to add: intro, verse, chorus, bridge, solo or outro")
        }
        // Where: after the named section; intros first; outros last;
        // anything else before the outro, if there is one.
        var at = song.sections.count
        if let target = step.target, let last = indices(target, in: song).max() {
            at = last + 1
        } else if kind == .intro {
            at = 0
        } else if kind != .outro, let outro = song.sections.lastIndex(where: { $0.kind == .outro }) {
            at = outro
        }
        // The same groove as a section of the same kind, else its neighbour's.
        let model = song.sections.first { $0.kind == kind }
            ?? (at > 0 ? song.sections[at - 1] : song.sections.first)
        let groove = library.groove(model?.grooveID ?? GrooveLibrary.fallbackID)
        let bars = step.amount.map { Int($0.rounded()) } ?? model.flatMap { $0.kind == kind ? $0.bars : nil } ?? kind.defaultBars
        var section = Section(kind: kind, name: song.nextName(for: kind),
                              bars: min(max(bars, Section.barRange.lowerBound), Section.barRange.upperBound),
                              grooveID: groove.id, timeSignature: groove.timeSignature)
        if let model, model.kind == kind {
            section.feel = model.feel
            section.cymbals = model.cymbals
            section.time = model.time
        } else {
            section.cymbals = groove.naturalCymbals
        }
        if kind == .outro { section.fillIntoNext = .none }
        song.sections.insert(section, at: min(at, song.sections.count))
        let place = at == 0 ? "at the start" : at >= song.sections.count - 1 ? "at the end" : "after \(song.sections[at - 1].name)"
        outcome.done.append("Added \(section.name) (\(section.bars) bars) \(place)")
    }

    // MARK: Playback

    private func play(_ step: AssistantStep, song: Song, outcome: inout Outcome) {
        let playing = engine.isPlaying
        switch step.action {
        case .play:
            let from = step.target.flatMap { indices($0, in: song).first }.map { song.sections[$0].id }
            guard !song.sections.isEmpty else { return outcome.skipped.append("The song has no sections yet") }
            engine.play(from: from ?? engine.cuedSectionID)
            outcome.done.append("Playing from \(from.flatMap { id in song.sections.first { $0.id == id }?.name } ?? "the top")")
        case .stop:
            engine.stop()
            outcome.done.append("Stopped")
        case .nextSection, .previousSection, .restartSection, .fillNow, .bigEnding:
            guard playing else { return outcome.skipped.append("Press play first, then ask again") }
            let (action, words): (EngineController.QueuedAction, String) = switch step.action {
            case .nextSection: (.nextSection, "Next section coming up")
            case .previousSection: (.previousSection, "Back to the previous section")
            case .restartSection: (.restartSection, "Back to the top of this section")
            case .fillNow: (.fillNow, "Fill on the next bar")
            default: (.bigEnding, "Ending on the next bar")
            }
            engine.queue(action, source: "Voice")
            outcome.done.append(words)
        case .loop:
            if (step.amount ?? 1) < 0.5 {
                engine.setLoop(nil)
                outcome.done.append("Looping off")
                return
            }
            let id = step.target.flatMap { indices($0, in: song).first }.map { song.sections[$0].id }
                ?? engine.position?.sectionID ?? currentSectionID
            guard let id, let section = song.sections.first(where: { $0.id == id }) else {
                return outcome.skipped.append("Say which section to loop")
            }
            engine.setLoop(id)
            outcome.done.append("Looping \(section.name)")
        default:
            break
        }
    }

    // MARK: Targets

    /// The sections a target names, in song order. No target means the whole song.
    func indices(_ target: String?, in song: Song) -> [Int] {
        let all = Array(song.sections.indices)
        var t = (target ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "every ", "all the ", "all ", "each "] where t.hasPrefix(article) { t.removeFirst(article.count) }
        if t.isEmpty || ["all", "everything", "song", "whole song", "it", "section", "sections", "everywhere", "kit"].contains(t) {
            return all
        }
        if ["this", "this section", "this part", "here", "current", "selected", "now"].contains(t) {
            if let id = engine.position?.sectionID ?? currentSectionID, let i = song.index(of: id) { return [i] }
            return all
        }
        if let i = song.sections.firstIndex(where: { $0.name.lowercased() == t }) { return [i] }
        // "before chorus": the sections leading into it (where a fill into it goes).
        if t.hasPrefix("before ") {
            return Array(Set(indices(String(t.dropFirst(7)), in: song).compactMap { $0 > 0 ? $0 - 1 : nil })).sorted()
        }
        let words = t.split(separator: " ").map(String.init)
        for (w, word) in words.enumerated() {
            guard let kind = Self.kind(in: word) else { continue }
            let ofKind = all.filter { song.sections[$0].kind == kind }
            guard !ofKind.isEmpty else { return [] }
            if w + 1 < words.count, let n = Self.number(words[w + 1]), n >= 1, n <= ofKind.count { return [ofKind[n - 1]] }
            if w > 0 {
                switch words[w - 1] {
                case "first": return [ofKind[0]]
                case "second" where ofKind.count >= 2: return [ofKind[1]]
                case "third" where ofKind.count >= 3: return [ofKind[2]]
                case "last", "final": return [ofKind[ofKind.count - 1]]
                default: break
                }
            }
            return ofKind
        }
        if let i = song.sections.firstIndex(where: { $0.name.lowercased().contains(t) }) { return [i] }
        return []
    }

    private func describe(_ indices: [Int], in song: Song) -> String {
        if indices.count == song.sections.count && song.sections.count > 1 { return "every section" }
        if indices.count > 1 {
            let kind = song.sections[indices[0]].kind
            if indices.allSatisfy({ song.sections[$0].kind == kind }),
               indices.count == song.sections.filter({ $0.kind == kind }).count {
                return "the \(kind.pluralName)"
            }
        }
        let names = indices.map { song.sections[$0].name }
        return names.count <= 3 ? names.formatted(.list(type: .and)) : "\(names.count) sections"
    }

    private func noSection(_ target: String?) -> String {
        "There's no “\(target ?? "")” in this song"
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    // MARK: Vocabulary

    nonisolated static func kind(in word: String) -> SectionKind? {
        let w = word.lowercased()
        let table: [(SectionKind, [String])] = [
            (.intro, ["intro", "intros", "introduction", "beginning", "start"]),
            (.verse, ["verse", "verses"]),
            (.chorus, ["chorus", "choruses", "hook", "hooks", "refrain"]),
            (.bridge, ["bridge", "bridges", "middle eight", "break", "breakdown"]),
            (.solo, ["solo", "solos", "lead"]),
            (.outro, ["outro", "outros", "ending", "end", "coda"]),
        ]
        for (kind, names) in table where names.contains(w) { return kind }
        return nil
    }

    nonisolated static func number(_ word: String) -> Int? {
        if let n = Int(word) { return n }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                     "ten": 10, "twelve": 12, "sixteen": 16, "twenty": 20, "twenty four": 24, "thirty two": 32,
                     "sixty four": 64, "first": 1, "second": 2, "third": 3, "fourth": 4]
        return words[word]
    }

    /// A style named in the words ("funky" → Funk), or nil.
    nonisolated static func style(in words: String) -> String? {
        let table: [(String, [String])] = [
            ("Rock", ["rock", "rocky", "rock and roll"]), ("Blues & Shuffle", ["blues", "bluesy", "shuffle"]),
            ("Funk", ["funk", "funky", "funkier"]),
            ("Country", ["country", "train beat", "two step"]), ("Metal", ["metal", "heavy metal", "thrash"]),
            ("Punk", ["punk"]), ("Pop", ["pop", "poppy", "four on the floor", "disco", "dance"]),
            ("Ballad", ["ballad"]), ("Reggae", ["reggae", "ska", "dub", "one drop"]),
            ("Jazz & Swing", ["jazz", "jazzy", "jazzier", "bebop"]), ("Hip-hop", ["hiphop", "boom bap", "rap"]),
            ("Latin", ["latin", "bossa", "samba", "cha cha", "salsa"]),
        ]
        // Whole words only: "rap" isn't in "wrap it up".
        let padded = " " + PhraseInterpreter.normalize(words) + " "
        for (style, names) in table where names.contains(where: { padded.contains(" \($0) ") }) { return style }
        return nil
    }

    nonisolated static func pieces(_ value: String?) -> [Piece] {
        let v = (value ?? "").lowercased()
        if v.contains("kick") || v.contains("bass drum") { return [.kick] }
        if v.contains("snare") { return [.snare] }
        if v.contains("hat") { return [.hiHat, .openHat] }
        if v.contains("ride") { return [.ride] }
        if v.contains("crash") { return [.crash] }
        if v.contains("cymbal") { return [.ride, .crash, .hiHat, .openHat] }
        if v.contains("tom") { return [.highTom, .lowTom, .floorTom] }
        return Piece.allCases
    }

    nonisolated static func piecesName(_ value: String?) -> String {
        switch pieces(value) {
        case [.kick]: "kick"
        case [.snare]: "snare"
        case [.hiHat, .openHat]: "hi-hats"
        case [.ride]: "ride"
        case [.crash]: "crash"
        case [.ride, .crash, .hiHat, .openHat]: "cymbals"
        case [.highTom, .lowTom, .floorTom]: "toms"
        default: "kit"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
