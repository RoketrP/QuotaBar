import Charts
import QuotaBarCore
import SwiftUI

@MainActor
final class UsageHistoryWindowController {
    static let shared = UsageHistoryWindowController()
    private var window: NSWindow?

    func show(preview: Bool = false) {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "QuotaBar · 本地用量历史"
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 640, height: 480)
#if DEBUG
            panel.contentView = NSHostingView(rootView: UsageHistoryView(service: preview ? .preview() : nil))
            if preview { panel.title += "（演示数据）" }
#else
            panel.contentView = NSHostingView(rootView: UsageHistoryView())
#endif
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct UsageHistoryView: View {
    @ObservedObject private var service: UsageHistoryService
    init(service: UsageHistoryService? = nil) { self.service = service ?? .shared }
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var days = 7
    @State private var selectedSeries = ""
    @State private var confirmsClear = false

    private struct Series: Identifiable, Hashable {
        let bucket: String
        let minutes: Int
        let label: String
        var id: String { "\(bucket):\(minutes)" }
    }
    private var series: [Series] {
        var seen = Set<String>()
        return service.history.samples.compactMap { sample in
            let value = Series(bucket: sample.bucketID, minutes: sample.durationMinutes,
                               label: "\(sample.bucketID) · \(sample.windowLabel)")
            return seen.insert(value.id).inserted ? value : nil
        }.sorted { $0.id < $1.id }
    }
    private var active: Series? { series.first { $0.id == selectedSeries } ?? series.first }
    private var samples: [UsageHistorySample] {
        guard let active else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        return service.history.samples.filter {
            $0.bucketID == active.bucket && $0.durationMinutes == active.minutes && $0.timestamp >= cutoff
        }
    }
    private var points: [UsageHistoryPlotPoint] { UsageHistoryPlotPoint.make(samples: samples) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("额度的变化，留在本机。")
                        .font(.title2.weight(.semibold))
                    Text("只记录成功读取的额度快照；离线和休眠期间不补填数据。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("时间范围", selection: $days) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                }.pickerStyle(.segmented).frame(width: 150)
            }
            HStack {
                Toggle("记录本地历史", isOn: $preferences.historyEnabled).toggleStyle(.switch)
                Spacer()
                if !series.isEmpty {
                    Picker("额度窗口", selection: Binding(get: { active?.id ?? "" }, set: { selectedSeries = $0 })) {
                        ForEach(series) { Text($0.label).tag($0.id) }
                    }.frame(maxWidth: 320)
                }
            }
            if samples.isEmpty {
                ContentUnavailableView(
                    preferences.historyEnabled ? "等待第一条额度快照" : "尚未启用历史记录",
                    systemImage: "chart.xyaxis.line",
                    description: Text("启用后从下一次成功刷新开始记录，不导入演示数据。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("采样时间", point.sample.timestamp),
                             y: .value("剩余额度", point.sample.remainingPercent),
                             series: .value("连续采样段", point.segment))
                        .interpolationMethod(.linear)
                        .foregroundStyle(.green)
                    PointMark(x: .value("采样时间", point.sample.timestamp),
                              y: .value("剩余额度", point.sample.remainingPercent))
                        .symbolSize(8).foregroundStyle(.green)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent)%") } }
                } }
                .chartXScale(domain: Date().addingTimeInterval(-Double(days) * 86400)...Date())
                .accessibilityLabel("\(active?.label ?? "额度")剩余比例趋势，\(samples.count) 条采样")
                .frame(minHeight: 190)
            }
            if let error = service.errorMessage {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("打开数据目录") { service.revealDataFolder() }
                }
            }
            Divider()
            HStack {
                Text("保留 30 天 · 不含邮箱或凭证 · 退出或切换账户时清空")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("导出 CSV") { service.exportCSV() }.disabled(service.history.samples.isEmpty)
                Button("清空…", role: .destructive) { confirmsClear = true }
            }
            Text("记录的是剩余比例，不是 token 或费用统计；关闭记录会保留已有历史。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .task { service.pruneExpired() }
        .alert("清空本地历史？", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { service.clear() }
        } message: { Text("这会删除本机保存的额度采样。已导出的文件不受影响。") }
    }
}
