import CLAYCore
import NetworkExtension
import SwiftUI

@main struct CLAYTunnelLabApp: App {
    var body: some Scene {
        WindowGroup { TunnelLabView() }
    }
}

private struct TunnelLabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection = LabConnection()
    @State private var input = ""
    @State private var nodes: [NodeProfile] = []
    @State private var selected: UUID?
    @State private var mode: LabConnection.Mode = .rule
    @State private var attemptedImport = false
    @State private var probing = false
    @State private var response: Bool?
    @FocusState private var editing: Bool

    private var chosen: NodeProfile? { nodes.first { $0.id == selected } }
    private var oversized: Bool { input.utf8.count > ProfileImporter.maxBytes }

    var body: some View {
        NavigationStack {
            Form {
                Section("lab.scope") {
                    Label("lab.scope.description", systemImage: "testtube.2")
                    Text(verbatim: "\(LabContract.destination):\(LabContract.port)")
                        .font(.caption.monospaced())
                }
                Section("Configuration text") {
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
                        attemptedImport = true
                    }
                    .disabled(input.isEmpty || oversized)
                    Button("Clear input", role: .destructive) {
                        input.removeAll()
                        resetNodes()
                    }
                    .disabled(input.isEmpty)
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
                .disabled(connection.active || connection.busy)
                Section("lab.status") {
                    Text(statusLabel)
                        .accessibilityAddTraits(.updatesFrequently)
                    if connection.failure { Label("lab.failed", systemImage: "exclamationmark.circle") }
                    if connection.active {
                        Button("lab.stop", role: .destructive) { connection.stop() }
                            .disabled(connection.status == .disconnecting)
                        if connection.status == .connected {
                            Button("lab.probe") {
                                probing = true
                                response = nil
                                Task {
                                    let passed = await LabProbe.run()
                                    if connection.status == .connected { response = passed }
                                    probing = false
                                }
                            }
                            .disabled(probing)
                            if let response { Text(response ? "lab.probePassed" : "lab.probeFailed") }
                        }
                    } else {
                        Button("lab.start") {
                            guard let chosen else { return }
                            editing = false
                            Task { await connection.start(node: chosen, mode: mode) }
                        }
                        .disabled(chosen == nil || connection.busy || probing)
                    }
                }
            }
            .navigationTitle("lab.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .task { await connection.refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await connection.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            connection.readStatus()
        }
        .onChange(of: connection.status) { status in
            if status != .connected { response = nil }
        }
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
        attemptedImport = false
    }
}
