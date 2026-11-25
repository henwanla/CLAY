import CLAYCore
import SwiftUI

@main
struct CLAYOfflineApp: App {
    var body: some Scene {
        WindowGroup { ConfigurationChecker() }
    }
}

private struct ConfigurationChecker: View {
    @State private var input = ""
    @State private var summary: OfflineSummary?
    @FocusState private var editing: Bool

    private var oversized: Bool { input.utf8.count > ProfileImporter.maxBytes }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $input)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 144)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityLabel(Text("Configuration text"))
                        .focused($editing)
                        .onChange(of: input) { _ in summary = nil }
                    if oversized {
                        Label("The configuration exceeds 2 MiB.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                    Button("Check locally") {
                        editing = false
                        summary = OfflineSummary(input)
                    }
                    .disabled(input.isEmpty || oversized)
                    Button("Load example") {
                        input = OfflineSummary.example
                    }
                    .disabled(!input.isEmpty)
                    Button("Clear input", role: .destructive) {
                        editing = false
                        input.removeAll()
                        summary = nil
                    }
                    .disabled(input.isEmpty)
                } header: {
                    Text("Configuration text")
                } footer: {
                    Text("Paste node links, a Base64 list, Clash YAML/JSON with inline nodes, or V2Ray/Xray JSON. Input stays in this app session.")
                }

                if let summary {
                    Section("Results") {
                        countRow(Text("Compatible nodes"), summary.accepted)
                        ForEach(summary.protocols, id: \.name) { entry in
                            countRow(Text(verbatim: entry.name), entry.count)
                        }
                    }
                    if !summary.issues.isEmpty {
                        Section("Issues") {
                            ForEach(summary.issues, id: \.kind) { entry in
                                countRow(issueLabel(entry.kind), entry.count)
                            }
                        }
                    }
                }

                Section("About this check") {
                    Label("Local compatibility check only. No subscription downloads, connection tests, or VPN.", systemImage: "checkmark.shield")
                    Text("Rules and remote providers are not evaluated. A compatible node is not necessarily reachable.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("CLAY Configuration Check")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func countRow(_ label: Text, _ count: Int) -> some View {
        LabeledContent {
            Text(count, format: .number)
                .monospacedDigit()
        } label: {
            label
        }
    }

    private func issueLabel(_ kind: ImportError) -> Text {
        switch kind {
        case .malformed: Text("Malformed configuration")
        case .unsupportedProtocol: Text("Unsupported protocol")
        case .unsupportedTransport: Text("Unsupported transport")
        case .unsupportedOption: Text("Unsupported option or node limit")
        case .invalidAccount: Text("Invalid credentials or server address")
        case .notProxyOutbound: Text("Not a proxy outbound")
        }
    }
}
