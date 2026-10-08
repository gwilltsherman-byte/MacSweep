import AppKit
import SwiftUI
import SweepCore

/// Sorting, filtering and row selection for one category page (see NavigationState for why this isn't @State).
final class CategoryPageState: ObservableObject {
    @Published var sortOrder = [KeyPathComparator(\Item.sortSize, order: .reverse)]
    @Published var search = ""
    @Published var riskFilter = -1
    @Published var focused = Set<Item.ID>()
}

struct CategoryView: View {
    let category: SweepCategory
    @EnvironmentObject private var model: AppModel
    @StateObject private var page = CategoryPageState()

    private var rows: [Item] {
        var items = model.visibleItems(category.id)
        if page.riskFilter >= 0 { items = items.filter { $0.risk.rawValue == page.riskFilter } }
        let query = page.search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            items = items.filter {
                $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query)
                    || $0.badgeText.localizedCaseInsensitiveContains(query)
            }
        }
        return items.sorted(using: page.sortOrder)
    }

    var body: some View {
        let state = model.state(category.id)
        let rows = self.rows
        VStack(spacing: 0) {
            header(state, rows: rows)
            Divider()
            switch state.phase {
            case .idle:
                placeholder(symbol: category.symbol, title: "Not scanned yet",
                            message: "Scan to see what's here.", action: ("Scan This Category", { model.scan([category.id]) }))
            case .scanning where state.items.isEmpty:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking through \(category.title.lowercased())…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                if rows.isEmpty {
                    placeholder(symbol: "checkmark.circle", title: state.items.isEmpty ? "Nothing found" : "No matches",
                                message: state.items.isEmpty ? "There's nothing to clean up here." : "Try a different filter.",
                                action: nil)
                } else {
                    table(rows)
                    if page.focused.count == 1, let id = page.focused.first, let item = model.item(id) {
                        Divider()
                        ItemDetailView(item: item)
                            .frame(height: 210)
                    }
                }
            }
        }
    }

    private func header(_ state: AppModel.CategoryState, rows: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(category.title, systemImage: category.symbol).font(.title2.bold())
                Spacer()
                if state.phase == .done {
                    Text(Fmt.bytes(state.total)).font(.title2.monospacedDigit())
                    Text(Fmt.count(model.visibleItems(category.id).count, "item")).foregroundStyle(.secondary)
                }
            }
            // No fixedSize here: outside a scroll view it would make the page's minimum height enormous
            // when the split view measures it at a narrow width.
            Text(category.summary)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            ForEach(state.notes, id: \.self) { note in
                InfoBanner(text: note, symbol: "exclamationmark.circle", tint: .orange)
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                    TextField("Filter", text: $page.search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                Picker("Rating", selection: $page.riskFilter) {
                    Text("All").tag(-1)
                    ForEach(Risk.allCases, id: \.self) { risk in
                        Text(risk.label).tag(risk.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
                Spacer()
                Button("Tick Safe") { model.check(rows.filter { $0.risk == .safe }.map(\.id), true) }
                    .help("Tick every item rated Safe in this list")
                Button("Tick All") { model.check(rows.map(\.id), true) }
                Button("Untick All") { model.check(rows.map(\.id), false) }
                Button {
                    model.scan([category.id])
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Scan this category again")
                .disabled(model.isScanning)
            }
            .disabled(state.phase == .idle)
        }
        .padding(16)
    }

    private func table(_ rows: [Item]) -> some View {
        Table(rows, selection: $page.focused, sortOrder: $page.sortOrder) {
            TableColumn("", value: \Item.title) { item in
                CheckCell(item: item)
            }
            .width(24)
            TableColumn("Name", value: \Item.title) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(item.note)
            }
            .width(min: 170, ideal: 220)
            TableColumn("Rating", value: \Item.risk) { item in
                RiskBadge(risk: item.risk)
            }
            .width(70)
            TableColumn("Size", value: \Item.sortSize) { item in
                Text(Fmt.bytes(item.size)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("Date", value: \Item.sortDate) { item in
                Text(item.date == nil ? "—" : "\(item.dateKind.rawValue) \(Fmt.date(item.date))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 115)
            TableColumn("Details", value: \Item.badgeText) { item in
                BadgeRow(item: item)
            }
            .width(min: 80, ideal: 120)
        }
        .contextMenu(forSelectionType: Item.ID.self) { ids in
            Button("Tick") { model.check(ids, true) }
            Button("Untick") { model.check(ids, false) }
            Divider()
            if ids.count == 1, let id = ids.first, let item = model.item(id), let path = item.paths.first {
                Button("Show in Finder") { AppModel.reveal(path) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.paths.joined(separator: "\n"), forType: .string)
                }
                Divider()
            }
            Button("Hide from Results") { model.ignore(ids) }
        } primaryAction: { ids in
            model.toggle(ids)
        }
    }

    private func placeholder(symbol: String, title: String, message: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.title3.bold())
            Text(message).foregroundStyle(.secondary)
            if let action {
                Button(action.0, action: action.1).disabled(model.isScanning)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CheckCell: View {
    let item: Item
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if item.isRemovable {
            Toggle("", isOn: Binding(get: { model.checked.contains(item.id) },
                                     set: { model.setChecked(item.id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
        } else {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)
                .help(item.manualRemoval ?? "MacSweep can't remove this itself.")
        }
    }
}

struct ItemDetailView: View {
    let item: Item
    @AppStorage("useTrash") private var useTrash = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.headline).textSelection(.enabled)
                    RiskBadge(risk: item.risk)
                    Spacer()
                    Text(Fmt.bytes(item.size)).font(.headline.monospacedDigit())
                }
                Text(item.note).fixedSize(horizontal: false, vertical: true)
                Text("\(item.risk.label): \(item.risk.explanation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let manual = item.manualRemoval {
                    InfoBanner(text: manual, symbol: "hand.raised", tint: .orange)
                }
                if !item.paths.isEmpty {
                    Text("Location\(item.paths.count == 1 ? "" : "s")").font(.caption.bold()).padding(.top, 4)
                    ForEach(Array(item.paths.prefix(25)), id: \.self) { path in
                        HStack(spacing: 6) {
                            Text(Fmt.path(path))
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button {
                                AppModel.reveal(path)
                            } label: {
                                Image(systemName: "arrow.right.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                        }
                    }
                    if item.paths.count > 25 {
                        Text("…and \(item.paths.count - 25) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("What removing it does").font(.caption.bold()).padding(.top, 4)
                let plan = RemovalPlan.describe([item], useTrash: useTrash, home: NSHomeDirectory())
                ForEach(Array(plan.prefix(15)), id: \.self) { line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }
                if plan.count > 15 {
                    Text("…and \(plan.count - 15) more steps").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
