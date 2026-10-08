import SwiftUI
import SweepCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    // "openCategory" can be passed as a launch argument (-openCategory apps) to start on a category.
    @State private var selection: String? = UserDefaults.standard.string(forKey: "openCategory") ?? "overview"

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 360)
        } detail: {
            VStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                SelectionBar()
            }
            .navigationSplitViewColumnWidth(min: 640, ideal: 900)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    ProgressView()
                        .controlSize(.small)
                    Button {
                        model.cancelScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop scanning")
                } else {
                    Button {
                        model.scanAll()
                    } label: {
                        Label(model.hasScanned ? "Scan Again" : "Scan Everything", systemImage: "magnifyingglass")
                    }
                    .help("Look through your Mac for everything that might be unnecessary")
                }
            }
        }
        .task {
            if UserDefaults.standard.bool(forKey: "scanOnLaunch") && !model.hasScanned {
                model.scanAll()
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .confirm:
                ConfirmRemovalView().environmentObject(model)
            case .progress:
                RemovalProgressView().environmentObject(model).interactiveDismissDisabled()
            case .results:
                RemovalResultsView().environmentObject(model)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, id != "overview", let category = model.category(id) {
            CategoryView(category: category)
                .id(id)
        } else {
            OverviewView(selection: $selection)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            HStack {
                Label("Overview", systemImage: "gauge")
                Spacer()
                if model.grandTotal > 0 {
                    Text(Fmt.bytes(model.grandTotal))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .tag("overview")

            ForEach(SweepSection.allCases) { section in
                Section(section.rawValue) {
                    ForEach(model.categories(in: section)) { category in
                        SidebarRow(category: category)
                            .tag(category.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SidebarRow: View {
    let category: SweepCategory
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let state = model.state(category.id)
        let selectedCount = state.items.filter { model.checked.contains($0.id) }.count
        HStack(spacing: 6) {
            Label(category.title, systemImage: category.symbol)
                .lineLimit(1)
            Spacer(minLength: 4)
            if selectedCount > 0 {
                Text("\(selectedCount)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .background(Color.accentColor.opacity(0.25), in: Capsule())
            }
            switch state.phase {
            case .scanning:
                ProgressView().controlSize(.mini)
            case .done:
                Text(summary(state))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
        }
    }

    private func summary(_ state: AppModel.CategoryState) -> String {
        let visible = state.items.filter { !model.ignored.contains($0.id) }
        if visible.isEmpty { return "—" }
        if state.total > 0 { return Fmt.bytes(state.total) }
        return "\(visible.count)"
    }
}

struct SelectionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let items = model.selectedItems
        HStack(spacing: 12) {
            Image(systemName: items.isEmpty ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(items.isEmpty ? Color.secondary : Color.accentColor)
            if items.isEmpty {
                Text("Tick items in any category to remove them.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(Fmt.count(items.count, "item")) selected · about \(Fmt.bytes(SizeMath.uniqueTotal(items)))")
                    .monospacedDigit()
            }
            Spacer()
            Button("Clear Selection") { model.checked = [] }
                .disabled(items.isEmpty)
            Button {
                model.requestRemoval()
            } label: {
                Label("Review & Remove…", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(items.isEmpty || model.isScanning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
