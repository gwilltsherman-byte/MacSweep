import SwiftUI
import SweepCore

struct ConfirmRemovalView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("useTrash") private var useTrash = true
    @State private var acknowledged = false
    @State private var showPlan = false

    var body: some View {
        let items = model.selectedItems
        let warnings = model.warnings(for: items, useTrash: useTrash)
        let needsAcknowledgement = items.contains { $0.risk == .caution }
        let groups = Dictionary(grouping: items, by: \.categoryID)
        let categories = model.categories.filter { groups[$0.id] != nil }

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove \(Fmt.count(items.count, "item"))?").font(.title2.bold())
                    Text("Frees about \(Fmt.bytes(SizeMath.uniqueTotal(items)))\(useTrash ? " once the Trash is emptied" : "").")
                        .foregroundStyle(.secondary)
                }
            }

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(warnings, id: \.self) { warning in
                        InfoBanner(text: warning, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            List {
                ForEach(categories) { category in
                    Section(category.title) {
                        ForEach(groups[category.id] ?? []) { item in
                            HStack {
                                Text(item.title).lineLimit(1)
                                if model.isRunning(item) { Chip(text: "Running", tint: .red) }
                                Spacer()
                                RiskBadge(risk: item.risk)
                                Text(Fmt.bytes(item.size))
                                    .monospacedDigit()
                                    .frame(width: 80, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .frame(height: 230)

            DisclosureGroup("Show exactly what will happen", isExpanded: $showPlan) {
                ScrollView {
                    Text(RemovalPlan.describe(items, useTrash: useTrash, home: NSHomeDirectory()).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
            }

            Toggle("Move files to the Trash so they can be put back", isOn: $useTrash)
            if needsAcknowledgement {
                Toggle("I understand that items marked Caution may contain my own data", isOn: $acknowledged)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    model.performRemoval(useTrash: useTrash)
                } label: {
                    Text(useTrash ? "Move to Trash" : "Delete Now")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(items.isEmpty || (needsAcknowledgement && !acknowledged))
            }
        }
        .padding(20)
        .frame(width: 660)
    }
}

struct RemovalProgressView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(model.progressMessage)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
            Text("Please keep MacSweep open. If macOS asks for your password, it's confirming administrator access for items outside your home folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 480)
    }
}

struct RemovalResultsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let outcome = model.outcome ?? RemovalOutcome()
        let failed = model.outcomeItems.filter { outcome.failures[$0.id] != nil }
        let removedCount = outcome.removed.count

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(failed.isEmpty ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Removed \(removedCount) of \(Fmt.count(model.outcomeItems.count, "item"))").font(.title2.bold())
                    Text("About \(Fmt.bytes(outcome.freedEstimate)) \(model.lastRemovalUsedTrash ? "moved out of the way. Empty the Trash to get the space back." : "freed.")")
                        .foregroundStyle(.secondary)
                }
            }

            if !failed.isEmpty {
                Text("These couldn't be removed:").font(.headline)
                List(failed) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).bold()
                        Text(outcome.failures[item.id] ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(height: 220)
                if !model.hasFullDiskAccess {
                    InfoBanner(text: "\"Operation not permitted\" usually means macOS is protecting the item. Full Disk Access fixes most of these.",
                               symbol: "lock", tint: .orange)
                }
            }

            HStack {
                if model.lastRemovalUsedTrash && removedCount > 0 {
                    Button("Empty Trash") { model.emptyTrash() }
                        .help("Asks Finder to empty the Trash, deleting everything in it for good")
                }
                Spacer()
                Button("Done") { model.sheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}
