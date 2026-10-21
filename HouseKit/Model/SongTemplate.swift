import Foundation

/// A ready-made song layout: sections, grooves and a tempo to start from.
/// Each section takes its time signature and cymbal from its groove.
struct SongTemplate: Identifiable {
    struct Part {
        var kind: SectionKind
        var bars: Int
        var groove: String
        var name: String? = nil          // nil numbers it like "Verse 2"
        var cymbals: CymbalChoice? = nil // nil keeps the groove's own
        var time: TimeFeel = .normal
        var fill: FillSize = .small
        var busy: Double? = nil
        var intensity: Double? = nil
        var vamp = false
    }

    let id: String
    let name: String
    let summary: String
    let bpm: Double
    var countInBars = 1
    let parts: [Part]

    /// The template's sections, numbered after any already in `song`.
    func sections(after song: Song, library: GrooveLibrary) -> [Section] {
        var scratch = song
        for (index, part) in parts.enumerated() {
            let groove = library.groove(part.groove)
            var section = Section(kind: part.kind, name: part.name ?? scratch.nextName(for: part.kind), bars: part.bars,
                                  grooveID: groove.id, timeSignature: groove.timeSignature)
            section.cymbals = part.cymbals ?? groove.naturalCymbals
            section.time = groove.timeSignature.allowsTimeFeel ? part.time : .normal
            section.fillIntoNext = index == parts.count - 1 ? .none : part.fill
            if let busy = part.busy { section.feel.busy = busy }
            if let intensity = part.intensity { section.feel.intensity = intensity }
            section.repeatUntilStep = part.vamp
            scratch.sections.append(section)
        }
        return Array(scratch.sections.suffix(parts.count))
    }

    /// Fills an empty song with the template: sections, tempo and count-in.
    func apply(to song: inout Song, library: GrooveLibrary) {
        song.sections += sections(after: song, library: library)
        song.bpm = bpm
        song.countInBars = countInBars
    }
}

extension SongTemplate {
    private typealias P = Part

    static let all: [SongTemplate] = [
        SongTemplate(
            id: "verseChorusRock", name: "Verse–Chorus Rock",
            summary: "Intro, two verses and choruses, and a half-time outro. The everyday song shape.",
            bpm: 112,
            parts: [
                P(kind: .intro, bars: 4, groove: "rock.straight8ths"),
                P(kind: .verse, bars: 8, groove: "rock.straight8ths"),
                P(kind: .chorus, bars: 8, groove: "rock.driving"),
                P(kind: .verse, bars: 8, groove: "rock.straight8ths"),
                P(kind: .chorus, bars: 8, groove: "rock.driving"),
                P(kind: .outro, bars: 4, groove: "rock.halfTime"),
            ]),
        SongTemplate(
            id: "classicRock", name: "Classic Rock",
            summary: "Verses on the hi-hat, choruses on the ride, a solo, a half-time bridge and one last chorus.",
            bpm: 124,
            parts: [
                P(kind: .intro, bars: 4, groove: "rock.driving"),
                P(kind: .verse, bars: 8, groove: "rock.straight8ths"),
                P(kind: .chorus, bars: 8, groove: "rock.ride"),
                P(kind: .verse, bars: 8, groove: "rock.straight8ths"),
                P(kind: .chorus, bars: 8, groove: "rock.ride"),
                P(kind: .solo, bars: 8, groove: "rock.driving", fill: .big, busy: 0.7, intensity: 0.7),
                P(kind: .bridge, bars: 8, groove: "rock.halfTime", fill: .big),
                P(kind: .chorus, bars: 8, groove: "rock.ride", intensity: 0.7),
                P(kind: .outro, bars: 4, groove: "rock.halfTime"),
            ]),
        SongTemplate(
            id: "twelveBarShuffle", name: "12-Bar Blues Shuffle",
            summary: "Twelve-bar choruses in a shuffle: three verses with a solo chorus before the last.",
            bpm: 110,
            parts: [
                P(kind: .intro, bars: 4, groove: "blues.shuffle"),
                P(kind: .verse, bars: 12, groove: "blues.shuffle"),
                P(kind: .verse, bars: 12, groove: "blues.shuffle"),
                P(kind: .solo, bars: 12, groove: "blues.drivingShuffle", fill: .big),
                P(kind: .verse, bars: 12, groove: "blues.shuffle"),
                P(kind: .outro, bars: 4, groove: "blues.halfTimeShuffle"),
            ]),
        SongTemplate(
            id: "slowBlues", name: "Slow Blues in 12/8",
            summary: "Twelve-bar slow blues. The solo repeats until you step, so take as many choruses as you like.",
            bpm: 60,
            parts: [
                P(kind: .intro, bars: 2, groove: "blues.twelveEight"),
                P(kind: .verse, bars: 12, groove: "blues.twelveEight"),
                P(kind: .verse, bars: 12, groove: "blues.twelveEight"),
                P(kind: .solo, bars: 12, groove: "blues.twelveEight", fill: .big, busy: 0.7, vamp: true),
                P(kind: .verse, bars: 12, groove: "blues.twelveEight"),
                P(kind: .outro, bars: 2, groove: "blues.twelveEight"),
            ]),
        SongTemplate(
            id: "countryTwoStep", name: "Country Two-step",
            summary: "Two-step verses, train-beat choruses and a fast solo.",
            bpm: 120,
            parts: [
                P(kind: .intro, bars: 4, groove: "country.twoStep"),
                P(kind: .verse, bars: 8, groove: "country.twoStep"),
                P(kind: .chorus, bars: 8, groove: "country.trainBeat"),
                P(kind: .verse, bars: 8, groove: "country.twoStep"),
                P(kind: .chorus, bars: 8, groove: "country.trainBeat"),
                P(kind: .solo, bars: 8, groove: "country.trainBeat", busy: 0.7),
                P(kind: .chorus, bars: 8, groove: "country.trainBeat"),
                P(kind: .outro, bars: 4, groove: "country.twoStep"),
            ]),
        SongTemplate(
            id: "countryWaltz", name: "Country Waltz",
            summary: "A waltz in 3/4 with sixteen-bar verses and a walking chorus.",
            bpm: 130,
            parts: [
                P(kind: .intro, bars: 4, groove: "country.waltz"),
                P(kind: .verse, bars: 16, groove: "country.waltz"),
                P(kind: .chorus, bars: 16, groove: "country.walkingWaltz"),
                P(kind: .verse, bars: 16, groove: "country.waltz"),
                P(kind: .chorus, bars: 16, groove: "country.walkingWaltz"),
                P(kind: .outro, bars: 4, groove: "country.waltz"),
            ]),
        SongTemplate(
            id: "powerBallad", name: "Ballad",
            summary: "Cross-stick intro, gentle verses, a building chorus and a sparse bridge.",
            bpm: 72,
            parts: [
                P(kind: .intro, bars: 4, groove: "ballad.crossStick", fill: .none),
                P(kind: .verse, bars: 8, groove: "ballad.slow8ths"),
                P(kind: .chorus, bars: 8, groove: "ballad.build"),
                P(kind: .verse, bars: 8, groove: "ballad.slow8ths"),
                P(kind: .chorus, bars: 8, groove: "ballad.build"),
                P(kind: .bridge, bars: 8, groove: "ballad.sparse", fill: .big),
                P(kind: .chorus, bars: 8, groove: "ballad.build", intensity: 0.75),
                P(kind: .outro, bars: 4, groove: "ballad.crossStick"),
            ]),
        SongTemplate(
            id: "sixEightBallad", name: "6/8 Ballad",
            summary: "A slow ballad in six: verses on the hi-hat, choruses on the ride.",
            bpm: 56,
            parts: [
                P(kind: .intro, bars: 4, groove: "ballad.sixEight"),
                P(kind: .verse, bars: 8, groove: "ballad.sixEight"),
                P(kind: .chorus, bars: 8, groove: "ballad.sixEightRide"),
                P(kind: .verse, bars: 8, groove: "ballad.sixEight"),
                P(kind: .chorus, bars: 8, groove: "ballad.sixEightRide"),
                P(kind: .outro, bars: 4, groove: "ballad.sixEight"),
            ]),
        SongTemplate(
            id: "funkJam", name: "Funk Jam",
            summary: "A tight verse groove that repeats until you step, an open-hat chorus and a half-time bridge.",
            bpm: 100,
            parts: [
                P(kind: .intro, bars: 4, groove: "funk.tight"),
                P(kind: .verse, bars: 8, groove: "funk.tight", vamp: true),
                P(kind: .chorus, bars: 8, groove: "funk.openHat"),
                P(kind: .bridge, bars: 8, groove: "funk.halfTime", fill: .big),
                P(kind: .chorus, bars: 8, groove: "funk.openHat"),
                P(kind: .outro, bars: 4, groove: "funk.tight"),
            ]),
        SongTemplate(
            id: "punk", name: "Punk",
            summary: "Fast and short: skate-beat verses, pop-punk choruses and a half-time breakdown.",
            bpm: 180,
            parts: [
                P(kind: .intro, bars: 4, groove: "punk.drive"),
                P(kind: .verse, bars: 8, groove: "punk.skate"),
                P(kind: .chorus, bars: 8, groove: "punk.popPunk"),
                P(kind: .verse, bars: 8, groove: "punk.skate"),
                P(kind: .chorus, bars: 8, groove: "punk.popPunk"),
                P(kind: .bridge, bars: 4, groove: "punk.halfTime", fill: .big),
                P(kind: .chorus, bars: 8, groove: "punk.popPunk"),
                P(kind: .outro, bars: 2, groove: "punk.drive"),
            ]),
        SongTemplate(
            id: "reggae", name: "Reggae One Drop",
            summary: "Long one-drop verses, steppers choruses and a dub outro.",
            bpm: 76,
            parts: [
                P(kind: .intro, bars: 4, groove: "reggae.oneDrop"),
                P(kind: .verse, bars: 16, groove: "reggae.oneDrop"),
                P(kind: .chorus, bars: 8, groove: "reggae.steppers"),
                P(kind: .verse, bars: 16, groove: "reggae.oneDrop"),
                P(kind: .chorus, bars: 8, groove: "reggae.steppers"),
                P(kind: .outro, bars: 4, groove: "reggae.dub"),
            ]),
        SongTemplate(
            id: "jazzStandard", name: "Jazz Standard (AABA)",
            summary: "A 32-bar AABA head in swing, solos that repeat until you step, then the head out.",
            bpm: 140,
            parts: [
                P(kind: .intro, bars: 4, groove: "jazz.twoFeel"),
                P(kind: .verse, bars: 8, groove: "jazz.mediumSwing", name: "A1"),
                P(kind: .verse, bars: 8, groove: "jazz.mediumSwing", name: "A2"),
                P(kind: .bridge, bars: 8, groove: "jazz.mediumSwing", name: "B"),
                P(kind: .verse, bars: 8, groove: "jazz.mediumSwing", name: "A3"),
                P(kind: .solo, bars: 32, groove: "jazz.mediumSwing", name: "Solos", busy: 0.65, vamp: true),
                P(kind: .verse, bars: 8, groove: "jazz.mediumSwing", name: "Head out"),
                P(kind: .outro, bars: 4, groove: "jazz.twoFeel"),
            ]),
        SongTemplate(
            id: "hipHop", name: "Hip-hop",
            summary: "Boom-bap verses, a laid-back hook and a sparse intro and outro.",
            bpm: 90,
            parts: [
                P(kind: .intro, bars: 4, groove: "hiphop.sparse"),
                P(kind: .verse, bars: 16, groove: "hiphop.boomBap"),
                P(kind: .chorus, bars: 8, groove: "hiphop.laidBack", name: "Hook"),
                P(kind: .verse, bars: 16, groove: "hiphop.boomBap"),
                P(kind: .chorus, bars: 8, groove: "hiphop.laidBack", name: "Hook 2"),
                P(kind: .outro, bars: 4, groove: "hiphop.sparse"),
            ]),
        SongTemplate(
            id: "practiceLoop", name: "Practice Loop",
            summary: "One four-bar groove that repeats until you step. Change the groove and practise over it.",
            bpm: 100, countInBars: 1,
            parts: [
                P(kind: .custom, bars: 4, groove: "rock.straight8ths", name: "Groove", fill: .none, vamp: true),
            ]),
    ]
}
