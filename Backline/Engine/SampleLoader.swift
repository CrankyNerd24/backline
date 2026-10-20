import Foundation

/// Loads the recorded kit bundled with the app (Library/Samples) into the
/// engine's sample bank, once at launch and off the main thread. Until it's
/// in, recorded sounds play their synthesized stand-ins.
nonisolated enum SampleLoader {
    static func loadBundledKit() {
        Task.detached(priority: .userInitiated) { _ = install(from: .main) }
    }

    /// Reads every `<sound>_v<layer>_r<take>.wav` in the bundle, wherever
    /// Xcode put it, and installs the bank. Returns how many takes loaded.
    static func install(from bundle: Bundle) -> Int {
        guard let root = bundle.resourceURL,
              let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
              let bank = bl_sample_bank_create() else { return 0 }
        var loaded = 0
        for case let url as URL in walker where url.pathExtension == "wav" {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard parts.count == 3, parts[1].hasPrefix("v"), parts[2].hasPrefix("r"),
                  let layer = UInt32(parts[1].dropFirst()) else { continue }
            let sound = bl_sound_index(String(parts[0]))
            guard sound >= 0 else { continue }
            if bl_sample_bank_add_wav(bank, UInt8(sound), layer, url.path(percentEncoded: false)) { loaded += 1 }
        }
        if loaded > 0 { bl_samples_install(bank) }
        return loaded
    }
}
