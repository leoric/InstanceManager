import SwiftUI
import AppKit

// MARK: - Model

final class SettingsModel: ObservableObject {
    @Published var sources: [Source]
    @Published var selection: String?

    init(sources: [Source]) {
        self.sources = sources
        self.selection = sources.first?.id
    }

    func add() {
        let id = "proc-" + String(UUID().uuidString.prefix(8)).lowercased()
        let s = Source(id: id, name: "New process", managed: true, cwd: "~", command: nil)
        sources.append(s)
        selection = s.id
    }

    func removeSelected() {
        guard let sel = selection, let i = sources.firstIndex(where: { $0.id == sel }) else { return }
        sources.remove(at: i)
        if sources.indices.contains(i) {
            selection = sources[i].id
        } else {
            selection = sources.last?.id
        }
    }

    func moveSelected(_ delta: Int) {
        guard let sel = selection, let i = sources.firstIndex(where: { $0.id == sel }) else { return }
        let j = i + delta
        guard sources.indices.contains(j) else { return }
        sources.swapAt(i, j)
    }

    var problems: [String] {
        var out: [String] = []
        for s in sources {
            let name = s.name.trimmingCharacters(in: .whitespaces)
            let label = name.isEmpty ? "Unnamed entry" : name
            if name.isEmpty { out.append("An entry has no name") }
            if s.managed {
                if (s.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append("\(label): command is empty")
                }
            } else {
                if (s.path ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append("\(label): file path is empty")
                }
            }
        }
        return out
    }

    /// Cleans up fields that don't belong to the entry kind.
    func normalized() -> [Source] {
        sources.map { src in
            var s = src
            s.name = s.name.trimmingCharacters(in: .whitespaces)
            if s.managed {
                s.type = nil
                s.path = nil
                let cwd = (s.cwd ?? "").trimmingCharacters(in: .whitespaces)
                s.cwd = cwd.isEmpty ? "~" : cwd
                s.command = (s.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                s.type = "file"
                s.cwd = nil
                s.command = nil
                s.path = (s.path ?? "").trimmingCharacters(in: .whitespaces)
            }
            return s
        }
    }
}

// MARK: - Views

private func optionalText(_ b: Binding<String?>) -> Binding<String> {
    Binding<String>(
        get: { b.wrappedValue ?? "" },
        set: { b.wrappedValue = $0.isEmpty ? nil : $0 }
    )
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var onSave: ([Source]) -> Bool
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 230)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.sources) { s in
                    HStack(spacing: 6) {
                        Image(systemName: s.managed ? "terminal" : "doc.text")
                            .foregroundColor(.secondary)
                        Text(s.name.isEmpty ? "Unnamed" : s.name)
                            .lineLimit(1)
                    }
                    .tag(s.id)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button { model.add() } label: { Image(systemName: "plus") }
                    .help("Add entry")
                Button { model.removeSelected() } label: { Image(systemName: "minus") }
                    .help("Remove selected entry")
                    .disabled(model.selection == nil)
                Spacer()
                Button { model.moveSelected(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Move up")
                    .disabled(model.selection == nil)
                Button { model.moveSelected(1) } label: { Image(systemName: "chevron.down") }
                    .help("Move down")
                    .disabled(model.selection == nil)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let idx = model.sources.firstIndex(where: { $0.id == model.selection }) {
            SourceEditor(source: $model.sources[idx])
        } else {
            Text("Select an entry on the left, or press + to add one.")
                .foregroundColor(.secondary)
        }
    }

    private var footer: some View {
        let problems = model.problems
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if problems.isEmpty {
                    Text("Saving restarts all managed processes.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(problems.prefix(3), id: \.self) { p in
                        Text(p).foregroundColor(.red)
                    }
                }
            }
            .font(.caption)
            Spacer()
            Button("Cancel") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Save & Apply") {
                if onSave(model.normalized()) { onClose() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!problems.isEmpty)
        }
        .padding(12)
    }
}

struct SourceEditor: View {
    @Binding var source: Source

    var body: some View {
        Form {
            TextField("Name", text: $source.name)

            Picker("Kind", selection: $source.managed) {
                Text("Process (started by Instance Manager)").tag(true)
                Text("Log file (read-only)").tag(false)
            }

            if source.managed {
                HStack {
                    TextField("Working directory", text: optionalText($source.cwd),
                              prompt: Text("~"))
                    Button("Choose…") { chooseFolder() }
                }
                TextField("Command", text: optionalText($source.command),
                          prompt: Text("python bot.py"), axis: .vertical)
                    .lineLimit(2...6)
                Text("Runs via /bin/zsh -l -c in the working directory.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack {
                    TextField("File path", text: optionalText($source.path),
                              prompt: Text("~/Library/Logs/app.log"))
                    Button("Choose…") { chooseFile() }
                }
                Text("The file is only watched: the menu shows when it was last updated.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            source.cwd = NSString(string: url.path).abbreviatingWithTildeInPath
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            source.path = NSString(string: url.path).abbreviatingWithTildeInPath
        }
    }
}
