import Defaults
import SwiftUI

struct AISettingsView: View {
    @Default(.aiRingWarnPercent) private var warn
    @ObservedObject private var model = AIStatusModel.shared

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showAIQuotaRing) {
                    Text("Show quota ring in the closed notch")
                }
                Defaults.Toggle(key: .showAIAlerts) {
                    Text("Show alerts for limits, account switches, and proxy outages")
                }
                HStack {
                    Text("Warn at")
                    Slider(value: $warn, in: 50...95, step: 5)
                    Text("\(Int(warn))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            } header: {
                Text("Closed notch")
            } footer: {
                Text("The ring follows the account that last answered a request through CLI Proxy and shows its tightest limit. It turns orange at the warning level and red near the limit. Music and notifications take its place while they're showing.")
            }
            Section {
                LabeledContent("CLI Proxy") {
                    Text(model.status.map { $0.proxyReachable ? "Connected" : ($0.proxyError ?? "Not set up") } ?? "Checking…")
                }
                LabeledContent("Claude accounts") { Text("\(model.status?.claudeAccounts.count ?? 0)") }
                LabeledContent("Codex limits") { Text(model.status?.codex == nil ? "No recent session" : "From Codex session files") }
                if model.status?.restartAvailable == true {
                    Button(model.restarting ? "Restarting…" : "Restart CLI Proxy") { model.restartProxy() }.disabled(model.restarting)
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Reads ~/.config/cliproxyapi/management-key and talks only to CLI Proxy on 127.0.0.1. Full account limits are fetched only while Tokens › Limits is open.")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("AI")
        .onAppear { model.refresh() }
    }
}
