import AppKit
import SwiftUI
import SweepCore

enum Fmt {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func path(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

extension Risk {
    var color: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .caution: return .red
        }
    }
}

extension Item {
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { date ?? .distantPast }
    var badgeText: String { badges.joined(separator: ", ") }
}

struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Text(risk.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(risk.color.opacity(0.18), in: Capsule())
            .foregroundStyle(risk.color)
            .help(risk.explanation)
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(tint)
    }
}

/// Shown inside table rows, so the model is passed in (see CheckCell).
struct BadgeRow: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            if model.isRunning(item) { Chip(text: "Running", tint: .red) }
            ForEach(item.badges, id: \.self) { badge in
                Chip(text: badge, tint: tint(for: badge))
            }
        }
    }

    func tint(for badge: String) -> Color {
        let lower = badge.lowercased()
        if lower.contains("broken") || lower.contains("unused") || lower.contains("obsolete") || lower.contains("older")
            || lower.contains("no matching") || lower.contains("gone") || lower.contains("unavailable") {
            return .green
        }
        if lower.contains("newest") || lower.contains("active") || lower.contains("default") || lower.contains("in use")
            || lower.contains("root") {
            return .red
        }
        if lower.hasPrefix("not ") || lower.contains("never") || lower.contains("no record") { return .orange }
        return .secondary
    }
}

struct InfoBanner: View {
    let text: String
    var symbol = "info.circle"
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
    }
}

struct FullDiskAccessCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.title)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Give MacSweep Full Disk Access to see everything").font(.headline)
                Text("Without it, macOS hides the Trash, Mail, Messages, Safari, device backups and other apps' data from MacSweep. Turn MacSweep on in System Settings › Privacy & Security › Full Disk Access, then quit and reopen it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { AppModel.openFullDiskAccessSettings() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One line of plain-language explanation with a bold lead-in ("What they are: …").
struct ExplainRow: View {
    let symbol: String
    let title: String
    let text: String
    var lines: Int? = 4

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            (Text(title).bold() + Text(" ") + Text(text))
                .lineLimit(lines)
        }
    }
}

/// "Ratings: Safe = … · Check first = … · Careful = …"
struct RiskLegend: View {
    var body: some View {
        Risk.allCases.reduce(Text("Ratings: ").bold()) { text, risk in
            text + Text(risk.label).bold().foregroundColor(risk.color)
                + Text(" means \(risk.meaning)" + (risk == Risk.allCases.last ? "." : " · "))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }
}

/// The explanation at the top of every category page, for people who aren't sure what these files are.
struct CategoryHelpBox: View {
    let help: CategoryHelp
    @AppStorage("showCategoryHelp") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .frame(width: 12)
                    Text("What are these, and is it safe to delete them?")
                        .font(.callout.bold())
                    if !expanded { Text("Show").font(.callout).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                // No fixedSize here (see CategoryView): the line limits keep the page's minimum height sane.
                ExplainRow(symbol: "questionmark.circle", title: "What they are:", text: help.whatItIs)
                ExplainRow(symbol: "trash", title: "If you delete them:", text: help.ifDeleted)
                if let tip = help.tip {
                    ExplainRow(symbol: "lightbulb", title: "Tip:", text: tip, lines: 3)
                }
                RiskLegend()
                    .padding(.leading, 24)
                Text("Click any item, or its \(Image(systemName: "info.circle")) button, to see exactly what it is and whether you can undo deleting it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 24)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
