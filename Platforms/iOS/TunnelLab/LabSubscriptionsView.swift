import CLAYCore
import SwiftUI

@MainActor struct LabSubscriptionsView: View {
    @Environment(\.dismiss) private var dismiss
    let select: (LabSubscriptionSummary, [NodeProfile]) -> Void
    private let store = LabSubscriptionStore.live
    @State private var items: [LabSubscriptionSummary] = []
    @State private var name = ""
    @State private var address = ""
    @State private var busy = false
    @State private var failure: LocalizedStringKey?
    @State private var removing: UUID?

    var body: some View {
        NavigationStack {
            Form {
                addSection.disabled(busy)
                cacheSection.disabled(busy)
                if busy { ProgressView("lab.subscription.working") }
                if let failure { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            }
            .navigationTitle("lab.subscription.title")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("lab.subscription.close") { dismiss() }.disabled(busy)
            } }
            .confirmationDialog("lab.subscription.confirm", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible, presenting: removing) { id in
                Button("lab.subscription.remove", role: .destructive) {
                    run {
                        try await store.remove(id)
                        items = try await store.summaries()
                    }
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .task {
            do { items = try await store.summaries() }
            catch { failure = "lab.subscription.failed" }
        }
    }

    private var addSection: some View {
        Section {
            TextField("lab.subscription.name", text: $name)
                .autocorrectionDisabled()
                .privacySensitive()
            SecureField("lab.subscription.address", text: $address)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .privacySensitive()
            Button("lab.subscription.add") {
                run {
                    try await store.add(name: name, address: address)
                    name = ""
                    address = ""
                    items = try await store.summaries()
                }
            }
            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } footer: {
            Text("lab.subscription.hint")
        }
    }

    private var cacheSection: some View {
        Section("lab.subscription.cache") {
            if items.isEmpty { Text("lab.subscription.empty").foregroundStyle(.secondary) }
            ForEach(items) { entry in row(entry) }
        }
    }

    private func row(_ entry: LabSubscriptionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let count = entry.count {
                if entry.name.isEmpty { Text("lab.subscription.unnamed").font(.headline) }
                else { Text(verbatim: entry.name).font(.headline).lineLimit(1) }
                HStack(spacing: 8) {
                    Label(count.formatted(), systemImage: "list.bullet")
                        .accessibilityLabel(Text("lab.subscription.nodes"))
                        .accessibilityValue(Text(count.formatted()))
                    if let updated = entry.updated {
                        Text(updated, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label("lab.subscription.unreadable", systemImage: "lock").foregroundStyle(.secondary)
            }
            HStack {
                if entry.count != nil {
                    Button("lab.subscription.use") {
                        run {
                            let body = try await store.load(entry.id)
                            let nodes = SubscriptionImporter.parse(body).profiles
                            guard !nodes.isEmpty else { throw LabSubscriptionError.invalidContent }
                            select(entry, nodes)
                            dismiss()
                        }
                    }
                    Button("lab.subscription.refresh") {
                        run {
                            try await store.refresh(entry.id)
                            items = try await store.summaries()
                        }
                    }
                }
                Spacer(minLength: 0)
                Button(role: .destructive) { removing = entry.id } label: {
                    Label("lab.subscription.remove", systemImage: "trash").labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.borderless)
        }
        .privacySensitive()
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch LabSubscriptionError.invalidAddress { failure = "lab.subscription.invalidAddress" }
            catch { failure = "lab.subscription.failed" }
        }
    }
}
