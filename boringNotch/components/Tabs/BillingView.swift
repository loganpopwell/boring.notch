import SwiftUI

/// The LumaCore billing report, read through the helper. It only polls while the Billing tab is open.
@MainActor final class BillingModel: ObservableObject {
    static let shared = BillingModel()
    @Published private(set) var status: NotchBillingStatus?
    @Published private(set) var loading = false
    private var connection: NSXPCConnection?

    private init() {}

    private func helper() -> BoringNotchXPCHelperProtocol? {
        if connection == nil {
            let value = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
            value.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
            value.invalidationHandler = { Task { @MainActor in BillingModel.shared.connection = nil } }
            value.resume(); connection = value
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in
            Task { @MainActor in BillingModel.shared.loading = false }
        } as? BoringNotchXPCHelperProtocol
    }

    func refresh() {
        guard !loading, let helper = helper() else { return }
        loading = true
        helper.readBillingReport { data in
            let next = data.flatMap { try? JSONDecoder().decode(NotchBillingStatus.self, from: $0) }
            Task { @MainActor in
                let model = BillingModel.shared
                model.loading = false
                if let next { model.status = next }
            }
        }
    }
}

struct BillingView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var model = BillingModel.shared
    @State private var section = "overview"
    private let contentHeight: CGFloat = 186
    private static let reportURL = URL(string: "https://app.lumacoredesign.com/staff/invoices/report")!
    private let sections = [("overview", "Overview"), ("months", "By month"), ("upcoming", "Coming up"), ("recent", "Recent payments")]

    private var report: NotchBillingReport? { model.status?.report }
    private var problem: NotchBillingStatus.Problem? { model.status?.problem }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                ForEach(sections, id: \.0) { id, title in
                    pill(title, on: section == id) { section = id }
                }
                Spacer()
                Button { model.refresh() } label: {
                    if model.loading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                    .buttonStyle(.plain).frame(width: 16).disabled(model.loading).help("Refresh the billing report").accessibilityLabel("Refresh billing report")
                Button { NSWorkspace.shared.open(Self.reportURL) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain).help("Open the billing report in the dashboard").accessibilityLabel("Open billing report")
            }.font(.system(size: 11))
            Group {
                if let report {
                    switch section {
                    case "months": BillingMonthsChart(report: report)
                    case "upcoming": upcoming(report)
                    case "recent": recent(report)
                    default: overview(report)
                    }
                } else if let problem {
                    VStack(spacing: 8) {
                        Image(systemName: problem == .missingKey ? "key" : "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(.orange)
                        Text(Self.problemText(problem)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Reading the billing report…").controlSize(.small).font(.system(size: 11)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(height: contentHeight, alignment: .top)
            footer
        }
        .padding(.horizontal, 12).frame(width: 600)
        .onDisappear { if vm.notchState == .open { vm.notchSize.height = openNotchSize.height } }
        .task {
            withAnimation(.smooth(duration: 0.25)) { vm.notchSize.height = 320 }
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }

    static func problemText(_ problem: NotchBillingStatus.Problem) -> String {
        switch problem {
        case .missingKey: return "Add the dashboard's billing key to ~/.config/lumacore/notch-billing-key (owner-only)."
        case .unauthorized: return "The dashboard refused the billing key."
        case .unavailable: return "The dashboard couldn't build the billing report."
        case .offline: return "Can't reach the LumaCore dashboard."
        }
    }

    private var footer: some View {
        let warning = problem.map { Self.problemText($0) + (report == nil ? "" : " Showing the last report.") } ?? report?.warnings.first
        return HStack(spacing: 5) {
            Circle().fill(warning == nil ? .mint : .orange).frame(width: 4, height: 4)
            if let report {
                Text("Updated"); Text(report.generatedAt, style: .relative); Text("ago · LumaCore billing report")
            } else { Text("LumaCore billing report") }
            Spacer(minLength: 0)
            Text(warning ?? "Collected includes tax · before refunds and fees")
                .foregroundStyle(warning == nil ? Color.secondary : .orange)
                .help(report?.warnings.joined(separator: "\n") ?? "")
        }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
    }

    // MARK: Overview

    @ViewBuilder private func overview(_ r: NotchBillingReport) -> some View {
        let money = Self.money(currency: r.currency)
        let rec = r.recurring
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                metric("MRR", value: money(rec.mrr), tint: .mint,
                       subtitle: rec.mrr == nil ? "Couldn't verify every subscription" : "\(rec.customers) paying · before tax")
                metric("ARR", value: money(rec.arr), tint: .white, subtitle: "MRR × 12")
                metric("AT-RISK MRR", value: money(rec.atRiskMRR), tint: (rec.atRiskMRR ?? 0) > 0 ? .orange : .white,
                       subtitle: rec.pastDue > 0 ? "\(rec.pastDue) past due, not in MRR" : "Nothing past due")
                metric("POTENTIAL MRR", value: money(rec.potentialMRR), tint: .white,
                       subtitle: rec.trials > 0 ? "Includes \(money(rec.trialMRR)) from \(rec.trials) trial\(rec.trials == 1 ? "" : "s")" : "No trials converting")
            }.frame(height: 64)
            let month = Self.monthName(r.now.month, style: .wide)
            let facts: [(String, String, String, Color)] = [
                ("\(month) so far", money(r.thisMonth.collectedMonth),
                 r.thisMonth.refundedMonth > 0 ? "\(money(r.thisMonth.refundedMonth)) refunded" : "\(money(r.thisMonth.fees)) in Stripe fees", .cyan),
                ("\(String(r.thisYear.year)) collected", money(r.thisYear.collected), "\(r.thisYear.paymentCount) payments", .white),
                ("Monthly average", money(r.thisYear.averageMonth), "Over \(r.thisYear.monthsCounted) month\(r.thisYear.monthsCounted == 1 ? "" : "s")", .white),
                ("Annualized", money(r.thisYear.annualized), "Average × 12, not ARR", .white),
                ("Next 30 days", money(r.expected.next30Days), "\(money(r.expected.next90Days)) in 90 days", .white),
                ("Stripe balance", money(r.thisMonth.availableBalance), "\(money(r.thisMonth.pendingBalance)) pending",
                 r.thisMonth.availableBalance < 0 ? .orange : .white),
            ]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                ForEach(facts, id: \.0) { fact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.0).font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(fact.1).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(fact.3)
                        Text(fact.2).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.04)))
                }
            }
        }
    }

    // MARK: Lists

    @ViewBuilder private func upcoming(_ r: NotchBillingReport) -> some View {
        let money = Self.money(currency: r.currency)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                summary("Next 30 days", money(r.expected.next30Days))
                summary("Next 90 days", money(r.expected.next90Days))
                Spacer()
                Text("Stripe previews, soonest first").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if r.upcoming.isEmpty {
                Text("Nothing expected.").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Array(r.upcoming.enumerated()), id: \.offset) { _, row in
                            let automatic = row.collection == "Automatic charge"
                            listRow(date: row.date, customer: row.customer, amount: money(row.amount)) {
                                Text(automatic ? "Automatic" : "Invoice")
                                    .font(.system(size: 8, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill((automatic ? Color.mint : .cyan).opacity(0.16)))
                                    .foregroundStyle(automatic ? Color.mint : .cyan)
                            }
                        }
                    }
                }.scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder private func recent(_ r: NotchBillingReport) -> some View {
        let money = Self.money(currency: r.currency)
        if r.recent.isEmpty {
            Text("No payments yet.").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(r.recent.enumerated()), id: \.offset) { _, row in
                        listRow(date: row.date, customer: row.customer, amount: money(row.amount)) {
                            Text("\(row.source) · \(row.method)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }.scrollIndicators(.never)
        }
    }

    private func listRow<Detail: View>(date: Date, customer: String, amount: String, @ViewBuilder detail: () -> Detail) -> some View {
        HStack(spacing: 10) {
            Text(date.formatted(.dateTime.month(.abbreviated).day())).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text(customer).fontWeight(.medium).lineLimit(1).frame(width: 170, alignment: .leading)
            detail().frame(maxWidth: .infinity, alignment: .leading)
            Text(amount).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 11)).padding(.horizontal, 10).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.04)))
    }

    private func summary(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }

    // MARK: Shared pieces

    static func money(currency: String) -> (Int?) -> String {
        { cents in cents.map { (Double($0) / 100).formatted(.currency(code: currency.uppercased())) } ?? "—" }
    }

    static func monthName(_ month: Int, style: Date.FormatStyle.Symbol.Month) -> String {
        guard let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2000, month: month, day: 1)) else { return "" }
        return date.formatted(.dateTime.month(style))
    }

    private func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.mint.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }.buttonStyle(.plain).foregroundStyle(on ? Color.mint : .secondary)
    }

    private func metric(_ title: String, value: String, tint: Color, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 8, weight: .medium)).tracking(0.4).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
            Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .secondarySystemFill)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.08), lineWidth: 0.7))
    }
}

/// Collections for the last 12 months, with this year's sources beside them.
struct BillingMonthsChart: View {
    let report: NotchBillingReport
    @State private var hovered: String?
    private var focus: NotchBillingReport.Month? { report.months.first { $0.id == hovered } ?? report.months.last }
    private var money: (Int?) -> String { BillingView.money(currency: report.currency) }

    private func isCurrent(_ month: NotchBillingReport.Month) -> Bool { month.year == report.now.year && month.month == report.now.month }
    private func label(_ month: NotchBillingReport.Month) -> String {
        BillingView.monthName(month.month, style: .abbreviated) + (month.month == 1 ? " ’" + String(month.year % 100) : "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            chart
            sources.frame(width: 170)
        }
    }

    @ViewBuilder private var chart: some View {
        if report.months.isEmpty {
            Text("No payments yet.").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let peak = max(1, report.months.map(\.collected).max() ?? 1)
            VStack(alignment: .leading, spacing: 8) {
                if let focus {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(BillingView.monthName(focus.month, style: .wide) + " " + String(focus.year)).font(.system(size: 12, weight: .semibold))
                        Text(money(focus.collected)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.mint).monospacedDigit()
                        if isCurrent(focus) { Text("month to date").font(.system(size: 9)).foregroundStyle(.secondary) }
                        Spacer()
                    }
                }
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(report.months) { month in
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(month.id == focus?.id ? Color.mint : Color.mint.opacity(0.35))
                                .frame(height: max(2, 118 * CGFloat(month.collected) / CGFloat(peak)))
                            Text(label(month)).font(.system(size: 8)).lineLimit(1).fixedSize()
                                .foregroundStyle(month.id == focus?.id ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onHover { hovered = $0 ? month.id : (hovered == month.id ? nil : hovered) }
                        .help("\(BillingView.monthName(month.month, style: .wide)) \(String(month.year)): \(money(month.collected))")
                    }
                }
            }
        }
    }

    private var sources: some View {
        let total = max(1, report.sources.reduce(0) { $0 + $1.amount })
        let colors: [Color] = [.mint, .cyan, .indigo, .teal, .purple, .orange, .yellow]
        return VStack(alignment: .leading, spacing: 7) {
            Text("WHERE \(String(report.now.year))'S MONEY CAME FROM").font(.system(size: 8, weight: .medium)).tracking(0.4).foregroundStyle(.secondary)
            if report.sources.isEmpty {
                Text("No payments yet this year.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(Array(report.sources.enumerated()), id: \.element.id) { index, source in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(source.label).lineLimit(1)
                        Spacer(minLength: 4)
                        Text((Double(source.amount) / 100).formatted(.currency(code: report.currency.uppercased()).precision(.fractionLength(0))))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }.font(.system(size: 10))
                    GeometryReader { proxy in
                        Capsule().fill(colors[index % colors.count].opacity(0.85))
                            .frame(width: max(3, proxy.size.width * CGFloat(source.amount) / CGFloat(total)))
                    }.frame(height: 4)
                }
            }
        }
    }
}
