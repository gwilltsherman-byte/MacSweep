import SwiftUI
import SweepCore

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: String?

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !model.hasFullDiskAccess { FullDiskAccessCard() }
                if !model.hasScanned { introduction }
                ForEach(SweepSection.allCases) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.rawValue).font(.title3.bold())
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(model.categories(in: section)) { category in
                                CategoryCard(category: category, model: model) { selection = category.id }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: IconArt.image(size: 72))
            VStack(alignment: .leading, spacing: 4) {
                Text("MacSweep").font(.largeTitle.bold())
                if model.isScanning {
                    Text("Scanning… \(Fmt.bytes(model.grandTotal)) found so far")
                        .font(.title3).monospacedDigit().foregroundStyle(.secondary)
                } else if model.hasScanned {
                    Text("\(Fmt.bytes(model.grandTotal)) of possibly unnecessary stuff found")
                        .font(.title3).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("Find everything on your Mac that might not need to be there.")
                        .font(.title3).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isScanning {
                Button("Stop") { model.cancelScan() }
                    .controlSize(.large)
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        model.scanAll()
                    } label: {
                        Label(model.hasScanned ? "Scan Again" : "Start Scan", systemImage: "magnifyingglass")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if model.hasScanned {
                        Button("Select Everything Marked Safe") { model.checkAllSafe() }
                    }
                }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How it works").font(.headline)
            InfoBanner(text: "MacSweep looks through \(model.categories.count) kinds of things: caches, logs, leftovers of deleted apps, Homebrew and other package managers, developer tools, Docker, virtual machines, AI models, big, duplicate and old files, and more.", symbol: "magnifyingglass")
            InfoBanner(text: "Nothing is removed until you tick it and confirm. Files go to the Trash by default, and every item says what removing it does.", symbol: "checkmark.shield")
            InfoBanner(text: "Each item has a rating: Safe (rebuilt automatically), Review (probably unneeded, but check), or Caution (may hold your own data).", symbol: "gauge")
            InfoBanner(text: "macOS may ask whether MacSweep can access folders like Documents and Downloads, or control System Events (for login items). Allowing it lets MacSweep see more.", symbol: "hand.raised")
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The model is passed in rather than looked up from the environment (see CheckCell).
struct CategoryCard: View {
    let category: SweepCategory
    @ObservedObject var model: AppModel
    let open: () -> Void

    var body: some View {
        let state = model.state(category.id)
        let visible = state.items.filter { !model.ignored.contains($0.id) }
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: category.symbol)
                        .foregroundStyle(Color.accentColor)
                    Text(category.title).font(.headline).lineLimit(1)
                    Spacer()
                    if state.phase == .scanning { ProgressView().controlSize(.small) }
                }
                switch state.phase {
                case .idle:
                    Text("Not scanned").foregroundStyle(.secondary)
                case .scanning:
                    Text("Scanning…").foregroundStyle(.secondary)
                case .done:
                    HStack(alignment: .firstTextBaseline) {
                        Text(visible.isEmpty ? "Nothing found" : (state.total > 0 ? Fmt.bytes(state.total) : "—"))
                            .font(.title3.monospacedDigit())
                        Spacer()
                        if !visible.isEmpty {
                            Text(Fmt.count(visible.count, "item")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !visible.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Risk.allCases, id: \.self) { risk in
                                let count = visible.filter { $0.risk == risk }.count
                                if count > 0 { Chip(text: "\(count) \(risk.label)", tint: risk.color) }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(category.summary)
    }
}
