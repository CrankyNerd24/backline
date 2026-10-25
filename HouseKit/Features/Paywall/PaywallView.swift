import StoreKit
import SwiftUI

/// The HouseKit Full offer: what the player reached for, everything the one
/// purchase adds, the price from the App Store, and Restore Purchases.
struct PaywallView: View {
    @Environment(Purchases.self) private var purchases
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss

    let feature: Purchases.Feature

    private struct Unlock {
        let icon: String
        let text: String
    }

    private static let unlocks: [Unlock] = [
        Unlock(icon: "music.note.list", text: "All 12 styles and 99 grooves: funk, country, metal, punk, reggae, jazz, hip-hop and Latin"),
        Unlock(icon: "circle.grid.2x2", text: "All 12 kits, and the full Kit Editor: pick each drum's sound and save your own kits"),
        Unlock(icon: "square.stack", text: "As many songs as you like"),
        Unlock(icon: "square.grid.3x3", text: "The Pattern Editor, to write your own grooves"),
        Unlock(icon: "waveform.badge.magnifyingglass", text: "All 70 Sounds Like songs, and analyzing your own recordings"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Spacer()
                    Button("Not now") { dismiss() }
                        .buttonStyle(ChipButtonStyle())
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(feature.headline)
                        .font(Theme.condensed(34, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(feature.detail)
                        .font(Theme.body(16))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("HouseKit Full adds")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    ForEach(Self.unlocks, id: \.text) { item in
                        Label {
                            Text(item.text).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: item.icon).foregroundStyle(Theme.accent)
                        }
                        .font(Theme.body(16))
                    }
                }
                .padding(Theme.Radius.pad)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

                buyArea

                Text("One purchase, no subscription. Shared with your family through Family Sharing. Everything in the free version stays free.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .task { await purchases.loadProduct() }
        .onChange(of: purchases.isUnlocked) { _, unlocked in
            if unlocked { dismiss() }
        }
        .onDisappear { purchases.state = .idle }
    }

    @ViewBuilder private var buyArea: some View {
        VStack(spacing: 10) {
            if purchases.isUnlocked {
                Label("HouseKit Full is unlocked. Thank you!", systemImage: "checkmark.seal.fill")
                    .font(Theme.body(17, weight: .semibold))
                    .foregroundStyle(Theme.ok)
            } else if let product = purchases.product {
                Button {
                    Task { await buy(product) }
                } label: {
                    HStack {
                        if purchases.state == .purchasing { ProgressView().tint(Theme.onAccent) }
                        Text("Unlock for \(product.displayPrice)")
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(purchases.state == .purchasing)
                .accessibilityHint("Buys HouseKit Full, a one-time purchase")
            } else if purchases.loadingProduct {
                ProgressView("Asking the App Store…")
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    Task { await purchases.loadProduct() }
                } label: {
                    Text("Couldn't reach the App Store. Try again").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle())
            }

            if !purchases.isUnlocked {
                Button {
                    Task { await purchases.restore() }
                } label: {
                    Text("Restore Purchases").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(purchases.state == .purchasing)
            }

            switch purchases.state {
            case .pending:
                Text("Waiting for approval. HouseKit unlocks as soon as the purchase goes through.")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
            case .failed(let message):
                Text(message)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.accent)
            default:
                EmptyView()
            }
        }
    }

    private func buy(_ product: Product) async {
        purchases.state = .purchasing
        do {
            await purchases.complete(try await purchase(product))
        } catch {
            purchases.state = .failed("The purchase didn't go through. Try again, or tap Restore Purchases.")
        }
    }
}
