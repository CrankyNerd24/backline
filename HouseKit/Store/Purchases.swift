import Foundation
import Observation
import StoreKit
import SwiftUI

/// HouseKit is free to try, and one purchase, HouseKit Full, unlocks the
/// rest for good (no subscription; shared with the family through Family
/// Sharing). The free app is the whole app with fewer styles and kits and
/// three songs: building, Energy, Tell HouseKit, Play-along, pedals and
/// accessibility are never locked, and nothing already in a song stops
/// playing. Locks apply only where something new is chosen.
@Observable
final class Purchases {
    static let productID = "com.crankynerdnew.housekit.full"
    static let freeStyles: Set<String> = ["Rock", "Blues & Shuffle", "Pop", "Ballad", GrooveLibrary.myGroovesStyle]
    static let freeKitNames: Set<String> = ["Garage Kit", "Big Rusty"]
    static let freeSongLimit = 3
    private static let cacheKey = "housekitFullUnlocked"

    /// What the player reached for, so the offer can say so.
    enum Feature: Identifiable, Equatable {
        case full                 // from the song menu
        case style(String)
        case kit(String)
        case template(String)
        case moreSongs
        case export
        case patternEditor
        case kitSounds
        case saveKit
        case referenceSong(String)
        case analyze
        case saveGroove

        var id: String { "\(self)" }

        var headline: String {
            switch self {
            case .full: "HouseKit Full"
            case .style(let name): "\(name) is in HouseKit Full"
            case .kit(let name): "The \(name) is in HouseKit Full"
            case .template(let name): "“\(name)” is in HouseKit Full"
            case .moreSongs: "Keep more than \(Purchases.freeSongLimit) songs"
            case .export: "Export is in HouseKit Full"
            case .patternEditor: "The Pattern Editor is in HouseKit Full"
            case .kitSounds: "Choosing sounds is in HouseKit Full"
            case .saveKit: "Saving kits is in HouseKit Full"
            case .referenceSong(let title): "“\(title)” is in HouseKit Full"
            case .analyze: "Analyzing recordings is in HouseKit Full"
            case .saveGroove: "Saving grooves is in HouseKit Full"
            }
        }

        var detail: String {
            switch self {
            case .full: "Everything HouseKit can do, for good."
            case .style: "You can hear every groove first. The free styles are Rock, Blues & Shuffle, Pop and Ballad."
            case .kit: "The free kits are the Garage Kit and Big Rusty."
            case .template: "This template uses grooves from a style in HouseKit Full."
            case .moreSongs: "The free version keeps \(Purchases.freeSongLimit) songs. Delete one, or unlock as many as you like."
            case .export: "Save your songs as 24-bit WAV files to use anywhere."
            case .patternEditor: "Write your own grooves, step by step, and keep them in My grooves."
            case .kitSounds: "Pick each drum's sound from every recorded and synthesized kit, and mix them."
            case .saveKit: "Keep your own kits to use in any song."
            case .referenceSong: "You can hear its groove first. In the free version, Sounds Like builds songs in Rock, Blues & Shuffle, Pop and Ballad."
            case .analyze: "HouseKit listens to a recording you own and finds its tempo, feel and time."
            case .saveGroove: "Keep grooves in My grooves to use in any song."
            }
        }
    }

    enum State: Equatable {
        case idle, purchasing, pending
        case failed(String)
    }

    private(set) var isUnlocked: Bool
    private(set) var product: Product?
    private(set) var loadingProduct = false
    var state = State.idle
    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        // The last known answer, so a launch doesn't flash locks while
        // StoreKit checks; refresh() corrects it either way.
        isUnlocked = UserDefaults.standard.bool(forKey: Self.cacheKey)
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task {
            await refresh()
            await loadProduct()
        }
    }

    // MARK: Rules

    func allows(style: String) -> Bool { isUnlocked || Self.freeStyles.contains(style) }

    func allows(_ groove: Groove) -> Bool { allows(style: groove.style) }

    /// The player's own kits are always theirs.
    func allows(_ kit: Kit, in kits: KitLibrary) -> Bool {
        isUnlocked || Self.freeKitNames.contains(kit.name) || kits.userKits.contains { $0.id == kit.id }
    }

    func allows(_ template: SongTemplate, library: GrooveLibrary) -> Bool {
        isUnlocked || template.parts.allSatisfy { allows(library.groove($0.groove)) }
    }

    func canAddSong(to store: SongStore) -> Bool {
        isUnlocked || store.summaries.count < Self.freeSongLimit
    }

    /// A new song with a kit the free version has (Big Rusty) if its own
    /// isn't.
    func fitted(_ song: Song, kits: KitLibrary) -> Song {
        guard !allows(kits.kit(song.kitID), in: kits),
              let free = kits.builtIn.first(where: { $0.name == "Big Rusty" }) ?? kits.builtIn.first
        else { return song }
        var song = song
        song.kitID = free.id
        song.kitOverride = nil
        return song
    }

    // MARK: Buying

    func loadProduct() async {
        guard product == nil, !loadingProduct else { return }
        loadingProduct = true
        product = try? await Product.products(for: [Self.productID]).first
        loadingProduct = false
    }

    /// The result of the `purchase` environment action (which knows the
    /// window to show Apple's sheet in).
    func complete(_ result: Product.PurchaseResult) async {
        switch result {
        case .success(let verification):
            await handle(verification)
            state = isUnlocked ? .idle : .failed("The App Store couldn't confirm the purchase. Try Restore Purchases.")
        case .pending:
            state = .pending
        case .userCancelled:
            state = .idle
        @unknown default:
            state = .idle
        }
    }

    /// Restore Purchases: asks the App Store for this Apple ID's purchases.
    func restore() async {
        state = .purchasing
        do {
            try await AppStore.sync()
            await refresh()
            state = isUnlocked ? .idle : .failed("No HouseKit Full purchase on this Apple ID.")
        } catch StoreKitError.userCancelled {
            state = .idle
        } catch {
            state = .failed("Couldn't reach the App Store. Check your connection and try again.")
        }
    }

    /// What the device's App Store account owns right now, refunds and
    /// Family Sharing included.
    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        setUnlocked(owned)
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if transaction.productID == Self.productID { await refresh() }
        await transaction.finish()
    }

    private func setUnlocked(_ value: Bool) {
        if isUnlocked != value { isUnlocked = value }
        UserDefaults.standard.set(value, forKey: Self.cacheKey)
    }
}

// MARK: Showing the offer

extension View {
    /// Shows the HouseKit Full offer while `feature` is set.
    func unlockSheet(_ feature: Binding<Purchases.Feature?>) -> some View {
        modifier(UnlockSheet(feature: feature))
    }
}

private struct UnlockSheet: ViewModifier {
    @Environment(Purchases.self) private var purchases
    @Binding var feature: Purchases.Feature?

    func body(content: Content) -> some View {
        content.sheet(item: $feature) { feature in
            PaywallView(feature: feature)
                .environment(purchases)
        }
    }
}
