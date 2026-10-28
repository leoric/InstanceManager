import Foundation

/// Same format as procmon.json from the Python version.
struct Source: Codable, Identifiable {
    var id: String
    var name: String
    var managed: Bool
    var cwd: String?
    var command: String?
    var type: String?
    var path: String?

    enum CodingKeys: String, CodingKey { case id, name, managed, cwd, command, type, path }

    init(id: String, name: String, managed: Bool = true,
         cwd: String? = nil, command: String? = nil,
         type: String? = nil, path: String? = nil) {
        self.id = id
        self.name = name
        self.managed = managed
        self.cwd = cwd
        self.command = command
        self.type = type
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        managed = try c.decodeIfPresent(Bool.self, forKey: .managed) ?? true
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        path = try c.decodeIfPresent(String.self, forKey: .path)
    }
}

struct Config: Codable {
    var processes: [Source]   // other keys (e.g. max_log_lines) are ignored
}

func expandPath(_ p: String) -> String {
    NSString(string: p).expandingTildeInPath
}

enum ConfigStore {
    static let supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("InstanceManager", isDirectory: true)
    static let configURL = supportDir.appendingPathComponent("config.json")
    static let logsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/InstanceManager", isDirectory: true)

    /// Used when config.example.json is missing from the app bundle.
    private static let emptyConfig = "{\n  \"processes\": []\n}\n"

    static func ensureConfigExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: configURL.path) else { return }

        // Migrate from earlier names, newest first.
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = [
            supportDir.appendingPathComponent("instance-manager.json"),
            appSupport.appendingPathComponent("ProcMon/procmon.json"),
        ]
        for url in legacy where fm.fileExists(atPath: url.path) {
            if (try? fm.copyItem(at: url, to: configURL)) != nil { return }
        }

        // First launch: seed from the bundled config.example.json.
        if let example = Bundle.main.url(forResource: "config.example", withExtension: "json"),
           (try? fm.copyItem(at: example, to: configURL)) != nil {
            return
        }
        try? emptyConfig.write(to: configURL, atomically: true, encoding: .utf8)
    }
}
