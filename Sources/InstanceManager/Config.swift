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

    static func ensureConfigExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        // Migrate the config from the old "ProcMon" name, if present.
        let old = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProcMon/procmon.json")
        if !fm.fileExists(atPath: configURL.path), fm.fileExists(atPath: old.path) {
            try? fm.copyItem(at: old, to: configURL)
        }
        if !fm.fileExists(atPath: configURL.path) {
            try? defaultConfig.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    /// Written on first launch only. Two harmless examples that work on any Mac.
    static let defaultConfig = #"""
    {
      "processes": [
        {
          "id": "example-ping",
          "name": "Ping 1.1.1.1",
          "managed": true,
          "cwd": "~",
          "command": "ping 1.1.1.1"
        },
        {
          "id": "example-install-log",
          "name": "install.log",
          "managed": false,
          "type": "file",
          "path": "/var/log/install.log"
        }
      ]
    }
    """#
}
