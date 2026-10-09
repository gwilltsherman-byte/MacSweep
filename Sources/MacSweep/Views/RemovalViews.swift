import SwiftUI
import SweepCore

/// The confirmation sheet's own toggles (see NavigationState for why this isn't @State).
final class ConfirmationState: ObservableObject {
    @Published var acknowledged = false
    @Published var showPlan = false
}

struct ConfirmRemovalView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("useTrash") private var useTrash = true
    @StateObject private var confirmation = ConfirmationState()

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

            outcomeSummary(items)

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
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.title).lineLimit(1)
                                    if model.isRunning(item) { Chip(text: "Running", tint: .red) }
                                    Spacer()
                                    RiskBadge(risk: item.risk)
                                    Text(Fmt.bytes(item.size))
                                        .monospacedDigit()
                                        .frame(width: 80, alignment: .trailing)
                                }
                                Text(RemovalPlan.recovery(for: item, useTrash: useTrash, home: NSHomeDirectory()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .help(item.note)
                        }
                    }
                }
            }
            .frame(height: 250)

            DisclosureGroup("Show exactly what will happen", isExpanded: $confirmation.showPlan) {
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
                Toggle("I understand that items rated Careful may contain my own data and can't always be recovered",
                       isOn: $confirmation.acknowledged)
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
                .disabled(items.isEmpty || (needsAcknowledgement && !confirmation.acknowledged))
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    /// Plain-language summary of what happens to everything selected, grouped by whether it can be undone.
    private func outcomeSummary(_ items: [Item]) -> some View {
        let kinds = items.map { RemovalPlan.kinds(for: $0, useTrash: useTrash) }
        func count(_ kind: RecoveryKind) -> Int { kinds.filter { $0.contains(kind) }.count }
        let trash = count(.trash), uninstall = count(.uninstall), permanent = count(.permanent), admin = count(.admin)
        return VStack(alignment: .leading, spacing: 5) {
            Text("What will happen").font(.headline)
            if trash > 0 {
                ExplainRow(symbol: "arrow.uturn.backward.circle", title: "\(Fmt.count(trash, "item")) go to the Trash.",
                           text: "You can put them back from the Trash until you empty it.")
            }
            if uninstall > 0 {
                ExplainRow(symbol: "shippingbox", title: "\(Fmt.count(uninstall, "item")) will be uninstalled",
                           text: "by the tool that installed them (Homebrew, npm, Docker, Xcode…). You can install them again later.")
            }
            if permanent > 0 {
                ExplainRow(symbol: "xmark.bin", title: "\(Fmt.count(permanent, "item")) will be deleted for good.",
                           text: "These can't be put back (things already in the Trash, or tiny files like .DS_Store).")
            }
            if admin > 0 {
                ExplainRow(symbol: "lock", title: "\(Fmt.count(admin, "item")) need an administrator password",
                           text: "and are deleted for good rather than moved to the Trash.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
