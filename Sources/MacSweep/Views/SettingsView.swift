import AppKit
import SwiftUI
import SweepCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("largeFileMB") private var largeFileMB = 500
    @AppStorage("oldDownloadDays") private var oldDownloadDays = 90
    @AppStorage("duplicateMinKB") private var duplicateMinKB = 1000
    @AppStorage("extraFolders") private var extraFolders = ""
    @AppStorage("useTrash") private var useTrash = true
    @AppStorage("scanOnLaunch") private var scanOnLaunch = false

    private var folders: [String] {
        extraFolders.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Scan everything when MacSweep opens", isOn: $scanOnLaunch)
                Picker("Large files are at least", selection: $largeFileMB) {
                    ForEach([100, 250, 500, 1000, 2000, 5000], id: \.self) { mb in
                        Text(Fmt.bytes(Int64(mb) * 1_000_000)).tag(mb)
                    }
                }
                Picker("Downloads count as old after", selection: $oldDownloadDays) {
                    ForEach([30, 60, 90, 180, 365], id: \.self) { days in
                        Text("\(days) days").tag(days)
                    }
                }
                Picker("Check for duplicates of files from", selection: $duplicateMinKB) {
                    ForEach([100, 1000, 10_000, 100_000], id: \.self) { kb in
                        Text(Fmt.bytes(Int64(kb) * 1_000)).tag(kb)
                    }
                }
            }

            Section {
                ForEach(folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(Fmt.path(folder)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            extraFolders = folders.filter { $0 != folder }.joined(separator: "\n")
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…", action: addFolders)
            } header: {
                Text("Also search these folders")
            } footer: {
                Text("Your home folder is always searched. Add other drives or folders where you keep projects or big files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Removing") {
                Toggle("Move files to the Trash by default", isOn: $useTrash)
            }

            Section("Hidden items") {
                HStack {
                    Text(model.ignored.isEmpty ? "No items are hidden." : "\(Fmt.count(model.ignored.count, "item")) hidden from results.")
                    Spacer()
                    Button("Show Them Again") { model.clearIgnored() }
                        .disabled(model.ignored.isEmpty)
                }
            }

            Section("Permissions") {
                HStack {
                    Image(systemName: model.hasFullDiskAccess ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.hasFullDiskAccess ? Color.green : Color.orange)
                    Text(model.hasFullDiskAccess ? "Full Disk Access is on." : "Full Disk Access is off, so some places can't be scanned.")
                    Spacer()
                    Button("Open Privacy Settings") { AppModel.openFullDiskAccessSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 560)
        .onAppear { model.refreshEnvironment() }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.path).filter { !folders.contains($0) }
        extraFolders = (folders + added).joined(separator: "\n")
    }
}
