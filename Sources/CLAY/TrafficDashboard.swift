import Charts
import CLAYCore
import SwiftUI

private enum TrafficText {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    static func rate(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return bytes(value) + "/s"
    }
}

struct TrafficDashboard: View {
    @ObservedObject var model: Workspace
    private let upload = Color(red: 0.75, green: 0.35, blue: 0.17)
    private let download = Color(red: 0.11, green: 0.49, blue: 0.67)

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                figure("上传速度", value: TrafficText.rate(model.telemetry?.uploadRate), icon: "arrow.up", color: upload)
                figure("下载速度", value: TrafficText.rate(model.telemetry?.downloadRate), icon: "arrow.down", color: download)
                figure("活动连接", value: model.telemetry.map { String($0.connectionCount) } ?? "—", icon: "point.3.connected.trianglepath.dotted", color: .secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label("流量走势", systemImage: "waveform.path").font(.headline)
                    Spacer()
                    legend("上传", color: upload)
                    legend("下载", color: download)
                }
                plot
                HStack(spacing: 14) {
                    Text("会话累计 ↑ \(TrafficText.bytes(model.telemetry?.uploadTotal))")
                    Text("↓ \(TrafficText.bytes(model.telemetry?.downloadTotal))")
                    Spacer()
                    if model.telemetryStale { Text("刷新失败 · 显示上次数据").foregroundStyle(.orange) }
                    else if let sampled = model.telemetry?.sampledAt { Text(sampled, style: .time) }
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("只统计经过 CLAY 内核的流量；PAC 直连和其他应用自己的代理不计入。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
        }
    }

    @ViewBuilder private var plot: some View {
        if model.trafficHistory.count < 2 {
            VStack(spacing: 7) {
                Image(systemName: "chart.xyaxis.line").font(.title2)
                Text(!model.running ? "启动代理后显示实时流量" : model.telemetryStale ? "暂时读不到内核数据" : "正在收集流量样本")
            }.font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 175)
        } else {
            Chart(model.trafficHistory) { point in
                LineMark(x: .value("时间", point.time), y: .value("字节/秒", point.upload), series: .value("系列", "上传-\(point.segment)"))
                    .foregroundStyle(upload)
                LineMark(x: .value("时间", point.time), y: .value("字节/秒", point.download), series: .value("系列", "下载-\(point.segment)"))
                    .foregroundStyle(download)
            }
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { mark in
                    AxisGridLine()
                    AxisValueLabel {
                        if let value = mark.as(Int64.self) {
                            Text(TrafficText.rate(value))
                        } else if let value = mark.as(Double.self), value.isFinite {
                            Text(TrafficText.rate(value >= Double(Int64.max) ? .max : Int64(max(0, value))))
                        }
                    }
                }
            }
            .frame(height: 175).accessibilityLabel("实时上传和下载流量走势")
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        Label { Text(title) } icon: { Circle().fill(color).frame(width: 7, height: 7) }
            .font(.caption).foregroundStyle(.secondary)
    }

    private func figure(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(color) }
                .font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
    }
}

struct ConnectionDashboard: View {
    @ObservedObject var model: Workspace
    @State private var search = ""
    @State private var sort: Sort = .started
    @State private var confirmCloseAll = false

    private enum Sort: String, CaseIterable, Identifiable {
        case started = "最近建立", downloaded = "下载量", uploaded = "上传量"
        var id: Self { self }
    }

    private var visibleConnections: [ProxyConnection] {
        let filter = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = (model.telemetry?.connections ?? []).filter { row in
            filter.isEmpty || ([row.host, row.destinationIP, row.rule, row.rulePayload, row.network, row.type] + row.chains.map(model.routeLabel))
                .contains { $0.localizedCaseInsensitiveContains(filter) }
        }
        switch sort {
        case .started: return matches
        case .downloaded: return matches.sorted { $0.download > $1.download }
        case .uploaded: return matches.sorted { $0.upload > $1.upload }
        }
    }

    var body: some View {
        let rows = visibleConnections
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                TextField("搜索域名、IP、规则或节点", text: $search).textFieldStyle(.roundedBorder)
                Picker("排序", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }.fixedSize()
                Button("关闭全部…", role: .destructive) { confirmCloseAll = true }
                    .disabled(!canClose || (model.telemetry?.connectionCount ?? 0) == 0)
            }
            HStack {
                if let snapshot = model.telemetry {
                    Text("显示 \(rows.count) / \(snapshot.connectionCount) 条活动连接")
                    if model.telemetryStale { Text("· 上次快照").foregroundStyle(.orange) }
                } else { Text("等待内核连接数据") }
                Spacer()
            }.font(.caption).foregroundStyle(.secondary)
            if !model.connectionMessage.isEmpty { Text(model.connectionMessage).font(.callout).foregroundStyle(.secondary) }
            if rows.isEmpty {
                Label(emptyMessage, systemImage: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140)
            } else {
                LazyVStack(spacing: 7) { ForEach(rows) { row($0) } }
            }
        }
        .confirmationDialog("关闭全部活动连接？", isPresented: $confirmCloseAll, titleVisibility: .visible) {
            Button("关闭全部", role: .destructive) { model.closeConnection() }
            Button("取消", role: .cancel) {}
        } message: { Text("正在经过 CLAY 的请求会中断，之后的新连接仍可建立。") }
    }

    private var canClose: Bool { model.running && !model.telemetryStale && !model.connectionActionBusy }
    private var emptyMessage: String {
        if !model.running { return "启动代理后可查看活动连接" }
        if model.telemetryStale { return "暂时读不到内核数据" }
        if model.telemetry == nil { return "正在读取连接" }
        return search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无经过 CLAY 的活动连接" : "没有匹配的连接"
    }

    private func row(_ row: ProxyConnection) -> some View {
        let host = row.host.isEmpty ? row.destinationIP : row.host
        let label = host.isEmpty ? "未知目的地" : (row.destinationPort.map { "\(host.contains(":") ? "[\(host)]" : host):\($0)" } ?? host)
        let route = row.chains.map(model.routeLabel).joined(separator: " → ")
        let rule = [row.rule, row.rulePayload].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.headline.monospaced()).lineLimit(1).textSelection(.enabled).help(label)
                Text([row.type, row.network.uppercased(), rule, route].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text("↑ \(TrafficText.bytes(row.upload))  ↓ \(TrafficText.bytes(row.download))")
                if let start = row.start { Text(start, style: .time).foregroundStyle(.secondary) }
            }.font(.caption.monospacedDigit()).fixedSize(horizontal: true, vertical: false)
            Button { model.closeConnection(row.id) } label: { Image(systemName: "xmark.circle") }
                .help("关闭此连接").accessibilityLabel("关闭此连接").disabled(!canClose)
        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
