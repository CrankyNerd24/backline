import Foundation

/// Song → engine timeline (spec §4.2). Runs on the main thread; it gathers
/// patterns and settings and hands them to the C++ builder, which applies the
/// feel transforms and is fast enough to rerun on every edit.
enum TimelineBuilder {
    /// The engine takes ownership of the result via bl_engine_set_timeline.
    static func build(_ song: Song, library: GrooveLibrary) -> OpaquePointer? {
        var songDesc = BLSongDesc(countInBars: UInt8(clamping: min(max(song.countInBars, 0), 2)))
        let lastIndex = song.sections.count - 1
        let descs: [BLSectionDesc] = song.sections.enumerated().map { index, section in
            let groove = library.groove(section.grooveID)
            let patterns = section.patternOverride ?? groove.patterns
            var desc = BLSectionDesc()
            bl_section_desc_init(&desc)
            desc.key = section.engineKey
            desc.bars = UInt16(clamping: min(max(section.bars, Section.barRange.lowerBound), Section.barRange.upperBound))
            desc.main = patterns.main.engineValue
            desc.fill = patterns.fill.engineValue
            if section.patternOverride == nil, let small = groove.smallFill {
                desc.smallFill = small.engineValue
            }
            if let busy = patterns.main.busyLayer {
                desc.busyLayer = Pattern(resolution: patterns.main.resolution, lanes: busy).engineValue
            }
            desc.busy = Float(section.feel.busy)
            desc.intensity = Float(section.feel.intensity)
            desc.swing = Float(section.feel.swing)
            desc.human = Float(section.feel.human)
            desc.time = section.time.engineValue
            desc.cymbals = section.cymbals.engineValue
            desc.fillIntoNext = section.fillIntoNext.engineValue
            desc.repeatUntilStep = section.repeatUntilStep
            // The outro ends with a big ending (spec §4.4).
            desc.bigEnding = section.kind == .outro && index == lastIndex
            return desc
        }
        return descs.withUnsafeBufferPointer { bl_timeline_create(&songDesc, $0.baseAddress, UInt32($0.count)) }
    }
}

extension Section {
    /// Stable, non-zero 32-bit id the engine uses to follow a section across
    /// timeline rebuilds and to seed its randomness.
    var engineKey: UInt32 {
        let b = id.uuid
        let high = UInt32(b.0) << 24 | UInt32(b.1) << 16 | UInt32(b.2) << 8 | UInt32(b.3)
        let low = UInt32(b.12) << 24 | UInt32(b.13) << 16 | UInt32(b.14) << 8 | UInt32(b.15)
        let key = high ^ low
        return key == 0 ? 1 : key
    }

    func mainPattern(library: GrooveLibrary) -> Pattern {
        patternOverride?.main ?? library.groove(grooveID).patterns.main
    }
}

private extension TimeFeel {
    var engineValue: UInt8 {
        switch self {
        case .half: UInt8(BL_TIME_HALF)
        case .normal: UInt8(BL_TIME_NORMAL)
        case .double: UInt8(BL_TIME_DOUBLE)
        }
    }
}

private extension CymbalChoice {
    var engineValue: UInt8 {
        switch self {
        case .hihat: UInt8(BL_CYMBALS_HIHAT)
        case .ride: UInt8(BL_CYMBALS_RIDE)
        case .crash: UInt8(BL_CYMBALS_CRASH)
        }
    }
}

private extension FillSize {
    var engineValue: UInt8 {
        switch self {
        case .none: UInt8(BL_FILL_NONE)
        case .small: UInt8(BL_FILL_SMALL)
        case .big: UInt8(BL_FILL_BIG)
        }
    }
}
