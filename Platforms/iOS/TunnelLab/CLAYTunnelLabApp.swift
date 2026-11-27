import CLAYCore
import NetworkExtension
import SwiftUI

@main struct CLAYTunnelLabApp: App {
    var body: some Scene {
        WindowGroup { TunnelLabView() }
    }
}

private struct TunnelLabView: View {
    private enum TargetField: Hashable { case address, port }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection = LabConnection()
    @State private var input = ""
    @State private var nodes: [NodeProfile] = []
    @State private var selected: UUID?
    @State private var showSubscriptions = false
    @State private var subscriptionName: String?
    @State private var mode: LabConnection.Mode = .rule
    @State private var targetAddress = LabContract.demoTarget.address
    @State private var targetPort = String(LabContract.demoTarget.port)
    @State private var attemptedImport = false
    @State private var probeID: UUID?
    @State private var response: Bool?
    @FocusState private var editing: Bool
    @FocusState private var targetEditing: TargetField?

    private var chosen: NodeProfile? { nodes.first { $0.id == selected } }
    private var oversized: Bool { input.utf8.count > ProfileImporter.maxBytes }
    private var target: LabContract.Target? { LabContract.Target(address: targetAddress, port: targetPort) }

    var body: some View {
        NavigationStack {
            Form {
                targetSection
                Section("Configuration text") {
                    Button { showSubscriptions = true } label: {
                        Label("lab.subscription.title", systemImage: "tray.full")
                    }
                    if let subscriptionName {
                        LabeledContent("lab.subscription.source") {
                            if subscriptionName.isEmpty { Text("lab.subscription.unnamed") }
                            else { Text(verbatim: subscriptionName).lineLimit(1) }
                        }
                        .privacySensitive()
                    }
                    TextEditor(text: $input)
                        .font(.body.monospaced())
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($editing)
                        .accessibilityLabel(Text("Configuration text"))
                        .privacySensitive()
                        .onChange(of: input) { _ in resetNodes() }
                    if oversized { Label("The configuration exceeds 2 MiB.", systemImage: "exclamationmark.circle") }
                    Button("lab.import") {
                        editing = false
                        let result = ProfileImporter.read(input)
                        nodes = result.profiles
                        selected = nodes.first?.id
                        subscriptionName = nil
                        attemptedImport = true
                    }
                    .disabled(input.isEmpty || oversized)
                    Button("Clear input", role: .destructive) {
                        input.removeAll()
                        resetNodes()
                    }
                    .disabled(input.isEmpty && subscriptionName == nil)
                    if attemptedImport && nodes.isEmpty { Text("lab.noNodes").foregroundStyle(.secondary) }
                    if !nodes.isEmpty {
                        Picker("lab.node", selection: $selected) {
                            ForEach(nodes) { node in Text(verbatim: node.name).tag(Optional(node.id)) }
                        }
                        .privacySensitive()
                    }
                    Picker("lab.mode", selection: $mode) {
                        Text("lab.rule").tag(LabConnection.Mode.rule)
                        Text("lab.global").tag(LabConnection.Mode.global)
                    }
                }
                .disabled(connection.busy || connection.updating || (connection.active && connection.status != .connected))
                Section("lab.status") {
                    Text(statusLabel)
                        .accessibilityAddTraits(.updatesFrequently)
                    if connection.failure { Label("lab.failed", systemImage: "exclamationmark.circle") }
                    if connection.active {
                        Button("lab.stop", role: .destructive) {
                            resetProbe()
                            connection.stop()
                        }
                            .disabled(connection.status == .disconnecting)
                        if connection.status == .connected {
                            Text("lab.update.hint").foregroundStyle(.secondary)
                            Button("lab.update.apply") {
                                guard let chosen else { return }
                                editing = false
                                resetProbe()
                                Task { await connection.apply(node: chosen, mode: mode) }
                            }
                            .disabled(chosen == nil || connection.busy || connection.updating)
                            if connection.updating { ProgressView("lab.update.working") }
                            if let outcome = connection.updateOutcome {
                                Text(LocalizedStringKey("lab.update." + outcome.rawValue))
                                    .accessibilityAddTraits(.updatesFrequently)
                            }
                            if connection.liveTarget?.isDemo == true {
                                Button("lab.probe") {
                                    guard let live = connection.liveTarget else { return }
                                    let id = UUID()
                                    probeID = id
                                    response = nil
                                    Task {
                                        let passed = await LabProbe.run(for: live)
                                        guard probeID == id, connection.status == .connected else { return }
                                        response = passed
                                        probeID = nil
                                    }
                                }
                                .disabled(probeID != nil || connection.updating || connection.updateOutcome == .unknown)
                                if let response { Text(response ? "lab.probePassed" : "lab.probeFailed") }
                            } else if connection.liveTarget != nil {
                                Text("lab.target.customProbe").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Button("lab.start") {
                            guard let chosen, let target else { return }
                            editing = false
                            targetEditing = nil
                            Task { await connection.start(node: chosen, mode: mode, target: target) }
                        }
                        .disabled(chosen == nil || target == nil || connection.busy)
                    }
                }
            }
            .navigationTitle("lab.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .sheet(isPresented: $showSubscriptions) {
            LabSubscriptionsView { entry, imported in
                nodes = imported
                selected = imported.first?.id
                subscriptionName = entry.name
                attemptedImport = false
                editing = false
            }
        }
        .task { await connection.refresh() }
        .task(id: connection.status) {
            if connection.status == .connected { await connection.readLiveTarget() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await connection.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            connection.readStatus()
        }
        .onChange(of: connection.status) { status in
            if status != .connected { resetProbe() }
        }
        .onChange(of: selected) { _ in connection.draftChanged() }
        .onChange(of: mode) { _ in connection.draftChanged() }
    }

    private var targetSection: some View {
        Section("lab.scope") {
            Label("lab.scope.description", systemImage: "testtube.2")
            if connection.active {
                if let live = connection.liveTarget {
                    LabeledContent("lab.target.live") {
                        Text(verbatim: live.displayEndpoint).font(.body.monospaced()).privacySensitive()
                    }
                } else if connection.readingTarget {
                    ProgressView("lab.target.reading")
                } else if connection.status == .connected {
                    Text("lab.target.unknown").foregroundStyle(.secondary)
                    Button("lab.target.retry") { Task { await connection.readLiveTarget() } }
                        .disabled(connection.busy)
                }
                Text("lab.target.reconnect").foregroundStyle(.secondary)
            } else {
                Group {
                    LabeledContent("lab.target.address") {
                        TextField("lab.target.address", text: $targetAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.asciiCapable)
                            .focused($targetEditing, equals: .address)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("lab.target.tcpPort") {
                        TextField("lab.target.tcpPort", text: $targetPort)
                            .keyboardType(.numberPad)
                            .focused($targetEditing, equals: .port)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .font(.body.monospaced())
                .privacySensitive()
                .disabled(connection.busy)
                if target == nil {
                    Label("lab.target.invalid", systemImage: "exclamationmark.circle")
                }
                demoButton("lab.target.demo.ipv4", for: LabContract.demoTarget)
                demoButton("lab.target.demo.ipv6", for: LabContract.demoTarget6)
            }
        }
    }

    private func demoButton(_ label: LocalizedStringKey, for demo: LabContract.Target) -> some View {
        Button(label) {
            targetAddress = demo.address
            targetPort = String(demo.port)
        }
        .disabled(connection.busy || target == demo)
    }

    private var statusLabel: LocalizedStringKey {
        switch connection.status {
        case .connected: return "lab.connected"
        case .connecting, .reasserting: return "lab.connecting"
        case .disconnecting: return "lab.disconnecting"
        default: return "lab.disconnected"
        }
    }

    private func resetNodes() {
        nodes.removeAll()
        selected = nil
        subscriptionName = nil
        attemptedImport = false
    }

    private func resetProbe() {
        probeID = nil
        response = nil
    }
}
