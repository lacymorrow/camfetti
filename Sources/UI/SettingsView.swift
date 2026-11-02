import StoreKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var tips = TipJar()
    @State private var routeThroughRelay = AwayConfig.routeThroughRelay

    private static let tailscaleURL: URL = {
        #if os(iOS)
        URL(string: "https://tailscale.com/download/ios")!
        #else
        URL(string: "https://tailscale.com/download")!
        #endif
    }()

    var body: some View {
        NavigationStack {
            Form {
                #if os(iOS)
                if AwayConfig.isAvailable {
                    Section {
                        Toggle("Watch Through Away", isOn: $routeThroughRelay)
                            .onChange(of: routeThroughRelay) { _, on in
                                AwayConfig.routeThroughRelay = on
                                model.resetAllStreams()
                            }
                        Button("Use This Device as Bridge") {
                            dismiss()
                            model.bridgeMode = true
                        }
                    } header: {
                        Text("Away Preview")
                    } footer: {
                        Text("Plays every camera through the CamFetti relay and the bridge at home, even on Wi-Fi.")
                    }
                }
                #endif
                Section {
                    Link("Get Tailscale", destination: Self.tailscaleURL)
                } header: {
                    Text("Watch from Anywhere")
                } footer: {
                    Text("Install Tailscale on your phone and on a device at home. Then add each camera's Tailscale address in its details. CamFetti never sends your video through our servers.")
                }
                if !tips.products.isEmpty || !tips.preview.isEmpty {
                    Section {
                        ForEach(tips.products, id: \.id) { product in
                            Button { Task { await tips.buy(product) } } label: {
                                LabeledContent(product.displayName, value: product.displayPrice)
                            }
                        }
                        ForEach(tips.preview, id: \.name) { row in
                            Button {} label: { LabeledContent(row.name, value: row.price) }
                        }
                    } header: {
                        Text("Tip Jar")
                    } footer: {
                        Text(tips.thanked ? "Thank you. Truly." : "CamFetti is free and open source. Tips keep it going.")
                    }
                }
                Section("About") {
                    Link("Help", destination: URL(string: "https://camfetti.lacy.sh/support")!)
                    Link("Privacy", destination: URL(string: "https://camfetti.lacy.sh/privacy")!)
                    Link("Source Code", destination: URL(string: "https://github.com/lacymorrow/camfetti")!)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .inlineNavigationTitle()
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            #else
            .formStyle(.grouped)
            #endif
            .task { await tips.load() }
        }
    }
}

/// Optional tips. The section stays hidden until the products exist in App Store Connect.
@MainActor @Observable
final class TipJar {
    static let ids = ["sh.lacy.camfetti.tip.small", "sh.lacy.camfetti.tip.medium", "sh.lacy.camfetti.tip.large"]
    private(set) var products: [Product] = []
    private(set) var thanked = false
    /// Debug-only stand-in rows (`-previewTips`) for the App Store review screenshot.
    private(set) var preview: [(name: String, price: String)] = []

    func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-previewTips") {
            preview = [("Small Tip", "$1.99"), ("Medium Tip", "$4.99"), ("Large Tip", "$9.99")]
            return
        }
        #endif
        products = ((try? await Product.products(for: Self.ids)) ?? []).sorted { $0.price < $1.price }
    }

    func buy(_ product: Product) async {
        guard case let .success(verification)? = try? await product.purchase(),
              case let .verified(transaction) = verification else { return }
        await transaction.finish()
        thanked = true
    }
}
