import Foundation

/// Understands everyday requests without any model: "more swing", "make the
/// chorus punchier", "slow it down a bit", "add a bridge after the second
/// chorus", "next section". Works on every iPad, offline, instantly; the
/// on-device model handles anything looser when it's available.
nonisolated enum PhraseInterpreter {
    /// - Parameters:
    ///   - sectionNames: the song's section names, so "the hook" or "A1" can be found.
    ///   - kitNames: the kits that can be switched to.
    static func interpret(_ text: String, sectionNames: [String] = [], kitNames: [String] = []) -> [AssistantStep] {
        clauses(of: text).flatMap { steps(for: $0, sectionNames: sectionNames, kitNames: kitNames) }
    }

    // MARK: Clauses

    /// Lowercased words, with a few multi-word terms joined so they read as one.
    static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        for (from, to) in [("hi-hat", "hihat"), ("hi hat", "hihat"), ("high hat", "hihat"), ("half-time", "halftime"),
                           ("half time", "halftime"), ("double-time", "doubletime"), ("double time", "doubletime"),
                           ("hip-hop", "hiphop"), ("hip hop", "hiphop"), ("count-in", "countin"), ("count in", "countin"),
                           ("bass drum", "kick"), ("kick drum", "kick"), ("snare drum", "snare"), ("don't", "dont"),
                           ("let's", "lets"), ("it's", "its"), ("i'm", "im")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        let kept = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "|" || $0 == "%" ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func clauses(of text: String) -> [String] {
        var s = text.lowercased()
        for separator in [",", ";", ".", "!", "?", " and then ", " then ", " and ", " but ", " also ", " plus "] {
            s = s.replacingOccurrences(of: separator, with: " | ")
        }
        return s.split(separator: "|").map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    /// True if the clause contains any of the phrases as whole words.
    static func has(_ clause: String, _ phrases: [String]) -> Bool {
        let padded = " \(clause) "
        return phrases.contains { padded.contains(" \($0) ") }
    }

    // MARK: One clause

    static func steps(for c: String, sectionNames: [String], kitNames: [String]) -> [AssistantStep] {
        let target = Self.target(in: c, sectionNames: sectionNames)
        let size = magnitude(c)
        let less = has(c, ["less", "fewer", "reduce", "lower", "down", "remove", "no", "without", "not so", "too",
                           "turn off", "take out", "tone down", "dial back", "back off", "get rid of", "cut", "dont"])
        let sign: Double = less ? -1 : 1
        let words = c.split(separator: " ").map(String.init)

        // Playback: short commands.
        if has(c, ["stop looping", "stop the loop", "dont loop", "no loop", "unloop", "loop off"]) {
            return [AssistantStep(.loop, amount: 0)]
        }
        if ["stop", "stop it", "stop playing", "stop the drums", "pause", "halt", "stop the music", "thats enough"].contains(c) {
            return [AssistantStep(.stop)]
        }
        if has(c, ["next section", "next part", "move on", "go on", "next one", "skip", "skip ahead", "go to the next"]) {
            return [AssistantStep(.nextSection)]
        }
        if has(c, ["previous section", "previous part", "go back", "back up", "back one"]) {
            return [AssistantStep(.previousSection)]
        }
        if has(c, ["restart this section", "start this section over", "one more time", "again", "redo this section"]) {
            return [AssistantStep(.restartSection)]
        }
        if has(c, ["fill"]) && has(c, ["now", "give me", "throw", "throw in a", "do a", "hit a", "play a"]) && target == nil {
            return [AssistantStep(.fillNow)]
        }
        if has(c, ["end it", "wrap it up", "wrap up", "big ending", "bigending", "bring it home", "end the song",
                   "lets end", "finish it", "take it out"]) {
            return [AssistantStep(.bigEnding)]
        }
        if has(c, ["loop"]) {
            return [AssistantStep(.loop, target: target ?? "this", amount: less ? 0 : 1)]
        }
        if has(c, ["from the top", "from the beginning", "start over"]) {
            return [AssistantStep(.play)]
        }
        if let first = words.first, ["play", "start", "go", "hit", "lets", "count"].contains(first),
           AssistantApplier.style(in: c) == nil, !has(c, ["play a", "start with a"]) {
            if c == "lets go" || c == "go" || first != "lets" || has(c, ["lets play", "lets go"]) {
                return [AssistantStep(.play, target: target)]
            }
        }

        // Tempo.
        if let bpm = number(in: c), has(c, ["bpm", "tempo", "beats per minute", "at"]), (40...260).contains(bpm) {
            let relative = has(c, ["by", "up", "down", "faster", "slower"])
            if relative {
                return [AssistantStep(.changeTempo, amount: Double(bpm) * (has(c, ["down", "slower"]) ? -1 : 1))]
            }
            return [AssistantStep(.setTempo, amount: Double(bpm))]
        }
        if has(c, ["faster", "speed up", "speed it up", "quicker", "pick up the pace", "pick it up", "up the tempo",
                   "increase the tempo", "raise the tempo", "more tempo", "too slow"]) {
            return [AssistantStep(.changeTempo, amount: relativeBPM(c, default: 8 * size))]
        }
        if has(c, ["slower", "slow down", "slow it down", "slow it", "lower the tempo", "decrease the tempo", "too fast",
                   "less tempo", "calm the tempo"]) {
            return [AssistantStep(.changeTempo, amount: -relativeBPM(c, default: 8 * size))]
        }

        // Count-in.
        if has(c, ["countin"]) {
            let bars = number(in: c) ?? (has(c, ["no", "without", "dont", "remove", "off"]) ? 0 : 1)
            return [AssistantStep(.countIn, amount: Double(bars))]
        }

        // Structure.
        if has(c, ["add", "insert", "put in", "throw in", "include", "need a", "want a", "another"]),
           let kind = words.first(where: { AssistantApplier.kind(in: $0) != nil }), !has(c, ["fill", "swing"]) {
            var after: String?
            if let at = words.firstIndex(of: "after"), at + 1 < words.count {
                after = Self.target(in: words[(at + 1)...].joined(separator: " "), sectionNames: sectionNames)
            }
            let bars = has(c, ["bar", "bars"]) ? number(in: c).map(Double.init) : nil
            return [AssistantStep(.addSection, target: after, amount: bars, value: kind)]
        }
        if has(c, ["remove", "delete", "drop", "cut", "get rid of", "lose", "take out"]), let target {
            return [AssistantStep(.removeSection, target: target)]
        }
        if has(c, ["bar", "bars"]), let bars = number(in: c) {
            return [AssistantStep(.setBars, target: target ?? "this", amount: Double(bars))]
        }
        if has(c, ["repeat until", "keep looping", "vamp", "until i say", "until i step", "jam on", "keep repeating",
                   "repeat until i step"]) {
            return [AssistantStep(.repeatUntilStep, target: target ?? "this", amount: less ? 0 : 1)]
        }

        // Kit.
        if has(c, ["kit"]), let name = kitNames.sorted(by: { $0.count > $1.count }).first(where: { kit in
            let short = kit.lowercased().replacingOccurrences(of: " kit", with: "")
            return has(c, [normalize(kit), normalize(short)])
        }) {
            return [AssistantStep(.useKit, value: name)]
        }

        // A piece louder or quieter.
        if let piece = pieceWord(c), has(c, ["louder", "quieter", "softer", "turn up", "turn down", "more", "less", "up",
                                             "down", "boost", "lower", "raise", "bring up", "bring down", "too loud",
                                             "too quiet", "cant hear"]) {
            let down = has(c, ["quieter", "softer", "turn down", "less", "down", "lower", "bring down", "too loud"])
            return [AssistantStep(.pieceVolume, amount: (down ? -0.25 : 0.25) * size, value: piece)]
        }

        // Groove.
        if has(c, ["different groove", "different beat", "another groove", "another beat", "change the groove",
                   "change the beat", "something else", "new groove", "new beat", "switch it up"]) {
            return [AssistantStep(.groove, target: target, value: "different")]
        }
        if AssistantApplier.style(in: c) != nil, !has(c, ["kit"]) {
            return [AssistantStep(.groove, target: target, value: c)]
        }

        // Time feel and cymbals.
        if has(c, ["halftime"]) { return [AssistantStep(less ? .normalTime : .halfTime, target: target)] }
        if has(c, ["doubletime"]) { return [AssistantStep(less ? .normalTime : .doubleTime, target: target)] }
        if has(c, ["normal time", "regular time", "back to normal"]) { return [AssistantStep(.normalTime, target: target)] }
        if has(c, ["on the ride", "ride cymbal", "use the ride", "to the ride", "switch to ride", "play the ride"]) {
            return [AssistantStep(.onRide, target: target)]
        }
        if has(c, ["on the hihat", "on hihat", "use the hihat", "to the hihat", "back to hihat", "back to the hihat",
                   "hihat instead", "play the hihat"]) {
            return [AssistantStep(.onHiHat, target: target)]
        }
        if has(c, ["on the crash", "crash cymbal", "use the crash", "ride the crash", "bash the crash"]) {
            return [AssistantStep(.onCrash, target: target)]
        }
        if has(c, ["fill", "fills"]) {
            let value = less ? "none" : has(c, ["big", "bigger", "huge", "massive", "more", "longer"]) ? "big" : "small"
            return [AssistantStep(.fill, target: target, value: value)]
        }

        // Feel and sound: a clause can ask for several ("tighter and punchier").
        var out: [AssistantStep] = []
        let step = 0.25 * size
        func add(_ action: AssistantStep.Action, _ up: [String], _ down: [String], value: String? = nil) {
            let isUp = has(c, up), isDown = has(c, down)
            guard isUp || isDown else { return }
            let direction: Double = isDown && !isUp ? -1 : sign
            let perTarget: String? = [.punch, .room, .brightness].contains(action) ? nil : target
            out.append(AssistantStep(action, target: perTarget, amount: step * direction, value: value))
        }
        add(.swing, ["swing", "swung", "swingy", "swingier", "shuffle feel", "bouncy", "bounce", "bouncier", "lilt"],
            ["straight", "straighter", "no swing", "unswung"])
        add(.busy, ["busy", "busier", "more notes", "fuller", "complex", "more complex", "more going on", "fancier",
                    "more active", "more interesting"],
            ["simpler", "simple", "sparse", "sparser", "fewer notes", "minimal", "stripped", "stripped down", "basic",
             "plainer", "less busy", "too busy"])
        add(.intensity, ["harder", "louder", "intense", "more intense", "energy", "more energy", "energetic",
                         "aggressive", "heavier", "hit harder", "drive", "driving", "pump", "pumping", "power"],
            ["softer", "quieter", "gentle", "gentler", "calm", "calmer", "mellow", "mellower", "lighter", "chill",
             "chiller", "relaxed", "laid back", "quiet", "too loud"])
        add(.human, ["human", "loose", "looser", "sloppy", "natural feel", "less robotic", "more feel", "organic",
                     "live feel", "messier", "groovier"],
            ["tight", "tighter", "quantized", "robotic", "machine", "locked", "locked in", "precise", "on the grid",
             "cleaner"])
        add(.punch, ["punch", "punchy", "punchier", "slam", "slammin", "smack", "compressed", "compress", "fat", "fatter",
                     "thick", "thicker", "beefy", "beefier", "phat", "oomph", "hit hard"],
            ["less punch", "more natural", "more dynamic", "dynamic", "uncompressed", "thinner"])
        add(.room, ["reverb", "room", "roomy", "roomier", "ambience", "ambient", "space", "spacious", "echo", "wet",
                    "wetter", "bigger room", "live room", "stadium", "arena", "hall", "big room"],
            ["dry", "drier", "dryer", "dead", "less reverb", "no reverb", "less room", "too much reverb"])
        add(.brightness, ["bright", "brighter", "crisp", "crisper", "sharper", "sizzle", "sizzly", "more top", "airy",
                          "shiny", "cut through"],
            ["dark", "darker", "warm", "warmer", "muffled", "dull", "duller", "vintage", "less harsh", "smoother",
             "too bright", "too harsh"],
            value: pieceWord(c))
        return out
    }

    // MARK: Pieces of a clause

    /// Which sections the clause is about, as the applier reads them.
    static func target(in c: String, sectionNames: [String]) -> String? {
        if has(c, ["whole song", "everything", "all sections", "every section", "all of it", "the song", "everywhere"]) {
            return "all"
        }
        if has(c, ["this section", "this part", "here", "right here", "this bit"]) { return "this" }
        for name in sectionNames.sorted(by: { $0.count > $1.count }) {
            let n = normalize(name)
            if !n.isEmpty, has(c, [n]), n.split(separator: " ").contains(where: { AssistantApplier.kind(in: String($0)) == nil }) {
                return name
            }
        }
        let words = c.split(separator: " ").map(String.init)
        for (i, word) in words.enumerated() where AssistantApplier.kind(in: word) != nil {
            // "start" and "end" are too common to mean intro and outro alone.
            if ["start", "end", "beginning", "break", "lead"].contains(word) && !(i > 0 && words[i - 1] == "the") { continue }
            var t = word
            if i + 1 < words.count, let n = AssistantApplier.number(words[i + 1]), n <= 8 { t += " \(words[i + 1])" }
            if i > 0, ["first", "second", "third", "last", "final"].contains(words[i - 1]) { t = "\(words[i - 1]) \(t)" }
            let before = i > 0 && words[i - 1] == "into" || i > 1 && words[i - 2] == "into" && words[i - 1] == "the"
            return before ? "before \(t)" : t
        }
        return nil
    }

    static func magnitude(_ c: String) -> Double {
        if has(c, ["a lot", "way", "much", "lots", "really", "very", "tons", "loads", "super", "massively", "a ton"]) {
            return 1.8
        }
        if has(c, ["a bit", "a little", "slightly", "a touch", "a tad", "little bit", "somewhat", "bit"]) { return 0.5 }
        return 1
    }

    static func pieceWord(_ c: String) -> String? {
        for (word, piece) in [("kick", "kick"), ("snare", "snare"), ("hihat", "hats"), ("hihats", "hats"), ("hats", "hats"),
                              ("ride", "ride"), ("crash", "crash"), ("cymbals", "cymbals"), ("cymbal", "cymbals"),
                              ("toms", "toms"), ("tom", "toms")] where has(c, [word]) {
            return piece
        }
        return nil
    }

    /// The first number in the clause, in digits or words.
    static func number(in c: String) -> Int? {
        let words = c.split(separator: " ").map(String.init)
        for (i, w) in words.enumerated() {
            if let n = Int(w.replacingOccurrences(of: "%", with: "")) { return n }
            if i + 1 < words.count, let n = AssistantApplier.number("\(w) \(words[i + 1])") { return n }
            if !["first", "second", "third", "fourth"].contains(w), let n = AssistantApplier.number(w) { return n }
        }
        return nil
    }

    /// "faster by 10" → 10; otherwise the default.
    static func relativeBPM(_ c: String, default value: Double) -> Double {
        if let n = number(in: c), n > 0, n <= 60 { return Double(n) }
        return value.rounded()
    }
}
