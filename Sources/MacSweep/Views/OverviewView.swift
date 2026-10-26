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
                BeginnerGuide(categoryCount: model.categories.count)
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

/// A step-by-step guide for people who've never cleaned up a Mac before.
struct BeginnerGuide: View {
    let categoryCount: Int
    @AppStorage("showBeginnerGuide") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.bold()).frame(width: 12)
                    Text("New here? How to clean up safely").font(.headline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    step(1, "Click **Start Scan**. MacSweep only looks; it doesn't change or delete anything while scanning. It checks \(categoryCount) kinds of things.")
                    step(2, "Pick a category on the left. The box at the top explains, in plain words, what those files are and what happens if you delete them.")
                    step(3, "Click an item (or its \(Image(systemName: "info.circle")) button) to read what it is, what deleting it does, and whether you can undo it.")
                    step(4, "Not sure? Start with **Select Everything Marked Safe**. Safe items are rebuilt or downloaded again automatically, so nothing you need is lost.")
                    step(5, "Click **Review & Remove**. You'll see a summary before anything happens, and files go to the **Trash** first, so you can put them back until you empty the Trash.")
                }
                RiskLegend()
                DisclosureGroup("Words you'll see") {
                    VStack(alignment: .leading, spacing: 5) {
                        term("Cache", "a copy an app saves so it can load things faster. Deleting it is safe; the app makes a new one.")
                        term("Log", "a diary file where apps note what they did. Only useful for troubleshooting.")
                        term("Leftovers", "settings and data from apps you already deleted.")
                        term("Login item", "something that starts by itself when you log in to your Mac.")
                        term("Homebrew, npm, Python, Docker…", "tools programmers use. If you don't write code, you probably don't need what they installed.")
                        term("Administrator password", "the password of an admin account on this Mac. macOS asks for it before deleting files that belong to the whole Mac rather than just to you.")
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                InfoBanner(text: "macOS may ask whether MacSweep can open folders like Documents and Downloads, or control System Events (to list login items). Allowing it lets MacSweep see more. It never sends anything anywhere.",
                           symbol: "hand.raised")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.2), in: Circle())
            Text(text)
        }
    }

    private func term(_ word: String, _ meaning: String) -> some View {
        (Text(word).bold() + Text(": " + meaning))
            .font(.callout)
    }
}
