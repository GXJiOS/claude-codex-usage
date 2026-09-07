import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct HistorySelection {
    let provider: ProviderKind
    let start: Date
    let end: Date

    func records(from records: [HistoryRecord]) -> [HistoryRecord] {
        records.filter { $0.kind == provider && $0.at >= start && $0.at <= end }.sorted { $0.at < $1.at }
    }

    func export(_ records: [HistoryRecord], asCSV: Bool) throws -> Data {
        let visible = self.records(from: records)
        if asCSV {
            let formatter = ISO8601DateFormatter()
            let lines = visible.map { record in
                [formatter.string(from: record.at), record.provider,
                 record.session.map { String($0) } ?? "", record.weekly.map { String($0) } ?? "",
                 record.tokensToday.map { String($0) } ?? ""]
                    .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
            }
            return Data((["timestamp,provider,session_used_percent,weekly_used_percent,tokens_today"] + lines).joined(separator: "\r\n").appending("\r\n").utf8)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(visible)
    }
}

struct HistoryPage: View {
    private enum TimeRange: Int, CaseIterable {
        case hours5 = 5, hours24 = 24, days7 = 168, days30 = 720, days90 = 2160
        var seconds: TimeInterval { Double(rawValue) * 3600 }
        var title: String {
            switch self {
            case .hours5: return L("5 Hours")
            case .hours24: return L("24 Hours")
            case .days7: return L("7 Days")
            case .days30: return L("30 Days")
            case .days90: return L("90 Days")
            }
        }
    }
    private struct Point: Identifiable {
        let id: Int
        let at: Date
        let value: Double
        let series: String
    }
    private struct DayPoint: Identifiable {
        var id: Date { day }
        let day: Date
        let tokens: Int
    }

    @EnvironmentObject private var model: SettingsModel
    @EnvironmentObject private var store: UsageStore
    @State private var range: TimeRange = .hours24
    @State private var anchor = Date()
    @State private var offset = 0
    @State private var records: [HistoryRecord] = []
    @State private var loading = true
    @State private var exportError: String?

    private var end: Date { anchor.addingTimeInterval(-Double(offset) * range.seconds) }
    private var start: Date { end.addingTimeInterval(-range.seconds) }
    private var selection: HistorySelection { HistorySelection(provider: model.selectedProvider, start: start, end: end) }
    private var visibleRecords: [HistoryRecord] { selection.records(from: records) }
    private var canGoBack: Bool { records.contains { $0.kind == model.selectedProvider && $0.at < start } }
    private var points: [Point] {
        visibleRecords.enumerated().flatMap { index, record in
            var points: [Point] = []
            if let value = record.session, value.isFinite { points.append(Point(id: index * 2, at: record.at, value: value, series: "Session")) }
            if let value = record.weekly, value.isFinite { points.append(Point(id: index * 2 + 1, at: record.at, value: value, series: "Weekly")) }
            return points
        }
    }
    private var dailyTokens: [DayPoint] {
        var peaks: [Date: Int] = [:]
        for record in visibleRecords {
            if let tokens = record.tokensToday {
                let day = Calendar.current.startOfDay(for: record.at)
                peaks[day] = max(peaks[day] ?? 0, tokens)
            }
        }
        return peaks.map { DayPoint(day: $0.key, tokens: $0.value) }.sorted { $0.day < $1.day }
    }
    private var tokenAxisDates: [Date] {
        guard let last = dailyTokens.last?.day,
              let boundary = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return [] }
        return dailyTokens.map(\.day) + [boundary]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    PageHeader(title: "Usage History", subtitle: "Track quota and tokens over time")
                    Spacer()
                    Picker(L("Time range"), selection: $range) {
                        ForEach(TimeRange.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 110)
                }
                Picker(L("History provider"), selection: $model.selectedProvider) {
                    ForEach(ProviderKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                SettingsCard("Usage Overview", subtitle: L("%@ · percent of quota consumed", model.selectedProvider.displayName)) {
                    VStack(spacing: 12) {
                        if loading { ProgressView().frame(maxWidth: .infinity).frame(height: 170) }
                        else if points.isEmpty { emptyChart("No quota samples in this range") }
                        else {
                            let chartPoints = points
                            let counts = chartPoints.reduce(into: [String: Int]()) { $0[$1.series, default: 0] += 1 }
                            Chart(chartPoints) { point in
                                if point.series == "Session" {
                                    AreaMark(x: .value(L("Time"), point.at), yStart: .value(L("Baseline"), 0), yEnd: .value(L("Used"), point.value))
                                        .foregroundStyle(Color.accentColor.opacity(0.1)).interpolationMethod(.stepEnd)
                                }
                                LineMark(x: .value(L("Time"), point.at), y: .value(L("Used"), point.value), series: .value(L("Window"), point.series))
                                    .foregroundStyle(by: .value(L("Window"), L(point.series)))
                                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: point.series == "Weekly" ? [5, 3] : []))
                                    .interpolationMethod(.stepEnd)
                                if counts[point.series] == 1 {
                                    PointMark(x: .value(L("Time"), point.at), y: .value(L("Used"), point.value))
                                        .foregroundStyle(by: .value(L("Window"), L(point.series))).symbolSize(12)
                                }
                            }
                            .chartForegroundStyleScale([L("Session"): Color.accentColor, L("Weekly"): Color.indigo])
                            .chartXScale(domain: start...end)
                            .chartXScale(range: .plotDimension(padding: 18))
                            .chartYScale(domain: 0...100)
                            .chartXAxis {
                                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                                    AxisGridLine()
                                    AxisValueLabel(format: (range.rawValue <= 24 ? Date.FormatStyle.dateTime.hour().minute() : .dateTime.month(.abbreviated).day()).locale(L10n.locale))
                                        .font(.system(size: 9))
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                                    AxisGridLine()
                                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                                }
                            }
                            .chartLegend(position: .top, alignment: .trailing)
                            .frame(height: 170)
                        }
                        HStack {
                            Button { offset += 1 } label: { Image(systemName: "chevron.left") }
                                .disabled(!canGoBack).accessibilityLabel(L("Previous time range"))
                            Spacer(minLength: 4)
                            Text("\(Format.dateTime(start)) – \(Format.dateTime(end))")
                                .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2).multilineTextAlignment(.center)
                            Spacer(minLength: 4)
                            Button(L("Now")) { offset = 0; anchor = Date() }.disabled(offset == 0)
                            Button { offset = max(0, offset - 1) } label: { Image(systemName: "chevron.right") }
                                .disabled(offset == 0).accessibilityLabel(L("Next time range"))
                        }.buttonStyle(.plain).font(Typography.caption)
                    }
                }
                SettingsCard("Tokens per day", subtitle: "Highest daily count observed in the selected range · this Mac") {
                    if loading { ProgressView().frame(maxWidth: .infinity).frame(height: 130) }
                    else if dailyTokens.isEmpty { emptyChart("No token samples in this range") }
                    else {
                        Chart(dailyTokens) { point in
                            BarMark(x: .value(L("Day"), point.day, unit: .day), y: .value(L("Tokens"), point.tokens), width: .fixed(16))
                                .foregroundStyle(Color.accentColor.opacity(0.8)).cornerRadius(2)
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine()
                                AxisValueLabel { Text(Format.tokens(value.as(Int.self) ?? 0)) }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: tokenAxisDates) { _ in
                                AxisValueLabel(format: .dateTime.month(.abbreviated).day().locale(L10n.locale), centered: true)
                                    .font(.system(size: 9))
                            }
                        }
                        .frame(height: 130)
                    }
                }
                HStack {
                    if store.isPreview { Text(L("Preview data")).foregroundColor(.orange) }
                    Spacer()
                    Menu {
                        Button(L("Export JSON…")) { export(asCSV: false) }
                        Button(L("Export CSV…")) { export(asCSV: true) }
                    } label: { Label(L("Export visible data"), systemImage: "square.and.arrow.up") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(visibleRecords.isEmpty || loading)
                }.font(Typography.caption)
                SettingsCard("Storage") {
                    SettingRow(title: "Keep samples for", detail: "Usage is sampled at most every 15 minutes.") {
                        Picker(L("History retention"), selection: $model.settings.historyRetentionDays) {
                            ForEach(Settings.retentionChoices, id: \.self) { Text(L("%d days", $0)).tag($0) }
                        }.labelsHidden().frame(width: 110)
                    }
                }
            }.padding(Spacing.contentPadding)
        }
        .scrollIndicators(.hidden)
        .task(id: store.lastRefresh) { await reload() }
        .onChange(of: range) { _ in offset = 0; anchor = Date() }
        .onChange(of: model.selectedProvider) { _ in offset = 0 }
        .onChange(of: model.settings.historyRetentionDays) { _ in Task { await reload() } }
        .alert(L("Export failed"), isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button(L("OK")) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private func emptyChart(_ title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line").font(.system(size: 22))
            Text(L(title)).font(Typography.body)
            Text(L("Samples accumulate while QuotaBar runs.")).font(Typography.caption)
        }.foregroundColor(.secondary).frame(maxWidth: .infinity).frame(height: 150)
    }

    private func reload() async {
        loading = true
        let days = model.settings.historyRetentionDays
        if store.isPreview { records = PreviewData.history() }
        else { records = await Task.detached(priority: .userInitiated) { History.load(days: days) }.value }
        if offset == 0 { anchor = Date() }
        loading = false
    }

    private func export(asCSV: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = asCSV ? [.commaSeparatedText] : [.json]
        panel.nameFieldStringValue = "quotabar-\(model.selectedProvider.rawValue).\(asCSV ? "csv" : "json")"
        panel.title = L("Export history")
        panel.prompt = L("Export")
        panel.message = L("Export %@ samples from the visible time range.", model.selectedProvider.displayName)
        let selection = self.selection
        let records = self.records
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try selection.export(records, asCSV: asCSV).write(to: url, options: .atomic) }
            catch { exportError = error.localizedDescription }
        }
    }
}
