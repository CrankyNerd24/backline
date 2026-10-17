import Foundation

/// Song → engine timeline (spec §4.2). Runs on the main thread; it only
/// gathers patterns and hands them to the C++ builder, which is fast enough
/// to rerun on every edit.
enum TimelineBuilder {
    /// The engine takes ownership of the result via bl_engine_set_timeline.
    static func build(_ song: Song, library: GrooveLibrary) -> OpaquePointer? {
        let descs: [BLSectionDesc] = song.sections.map { section in
            var desc = BLSectionDesc()
            desc.key = section.engineKey
            desc.bars = UInt16(clamping: min(max(section.bars, Section.barRange.lowerBound), Section.barRange.upperBound))
            desc.main = section.mainPattern(library: library).engineValue
            return desc
        }
        return descs.withUnsafeBufferPointer { bl_timeline_create($0.baseAddress, UInt32($0.count)) }
    }
}

extension Section {
    /// Stable, non-zero 32-bit id the engine uses to follow a section across
    /// timeline rebuilds.
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
