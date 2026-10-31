import Foundation
import Darwin

enum RunState { case stopped, running, exited, failed }

/// Derived from the last line of output.
enum Health { case ok, warning, error }

/// Runs a command via `/bin/zsh -l -c` in its own session (setsid),
/// so the whole process group can be killed on stop.
/// All state is mutated on the main thread only.
final class ManagedProcess {
    let source: Source
    private(set) var state: RunState = .stopped
    private(set) var pid: pid_t = 0
    private(set) var startedAt: Date?
    private(set) var exitCode: Int32?
    private(set) var lastLine: String = ""
    var onChange: (() -> Void)?
    /// Called (main thread) when the health derived from the last output line changes while running.
    var onHealthChange: ((Health) -> Void)?

    private var stopRequested = false
    private var restartAfterExit = false
    private var readSources: [DispatchSourceRead] = []
    private let readQueue = DispatchQueue(label: "instancemanager.read")

    private let logQueue: DispatchQueue
    private var logHandle: FileHandle?
    private let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let ansi = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"

    init(source: Source) {
        self.source = source
        self.logQueue = DispatchQueue(label: "instancemanager.log.\(source.id)")
    }

    var logURL: URL {
        let safe = source.id.replacingOccurrences(of: "/", with: "_")
        return ConfigStore.logsDir.appendingPathComponent("\(safe).log")
    }

    /// Derived from the last output line (case-insensitive). If both words appear, the one
    /// that comes first wins, since log levels usually lead the line:
    /// "WARNING ... NetworkError" is a warning, "ERROR ... warning" is an error.
    var health: Health {
        let l = lastLine.lowercased()
        let e = l.range(of: "error")?.lowerBound
        let w = l.range(of: "warning")?.lowerBound
        switch (e, w) {
        case (nil, nil): return .ok
        case (.some, nil): return .error
        case (nil, .some): return .warning
        case let (.some(ei), .some(wi)): return ei < wi ? .error : .warning
        }
    }

    var uptime: TimeInterval? {
        guard state == .running, let s = startedAt else { return nil }
        return Date().timeIntervalSince(s)
    }

    // MARK: - Control

    func start() {
        guard state != .running else { return }
        guard let command = source.command, !command.isEmpty else {
            fail("no command configured")
            return
        }
        let cwd = expandPath(source.cwd ?? "~")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            fail("working directory missing: \(cwd)")
            return
        }

        write("[instance-manager] $ \(command)")

        var outFds: [Int32] = [0, 0]
        var errFds: [Int32] = [0, 0]
        guard pipe(&outFds) == 0 else { fail("pipe() failed"); return }
        guard pipe(&errFds) == 0 else {
            close(outFds[0]); close(outFds[1])
            fail("pipe() failed")
            return
        }
        for fd in outFds + errFds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFds[1], 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // The app ignores SIGTERM/SIGINT (to handle them itself); ignored signals are
        // inherited across exec, so reset them to default in the child.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        let spawnFlags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(spawnFlags))

        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }

        let script = "cd -- \"$IM_CWD\" || exit 127\n\(command)"
        var env = ProcessInfo.processInfo.environment
        env["IM_CWD"] = cwd
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:"
            + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")

        let argStrings: [String] = ["/bin/zsh", "-l", "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = []
        for a in argStrings { argv.append(strdup(a)) }
        argv.append(nil)

        var envp: [UnsafeMutablePointer<CChar>?] = []
        for (k, v) in env {
            let entry: String = k + "=" + v
            envp.append(strdup(entry))
        }
        envp.append(nil)

        defer {
            for p in argv { if let p = p { free(p) } }
            for p in envp { if let p = p { free(p) } }
        }

        var newPid: pid_t = 0
        let rc = posix_spawn(&newPid, "/bin/zsh", &actions, &attr, argv, envp)

        close(outFds[1])
        close(errFds[1])

        guard rc == 0 else {
            close(outFds[0]); close(errFds[0])
            fail("posix_spawn failed: \(String(cString: strerror(rc)))")
            return
        }

        pid = newPid
        state = .running
        startedAt = Date()
        exitCode = nil
        lastLine = ""
        stopRequested = false
        readSources.removeAll()
        attachReader(fd: outFds[0])
        attachReader(fd: errFds[0])
        write("[instance-manager] started (pid \(newPid))")

        let p = newPid
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            while waitpid(p, &status, 0) < 0 && errno == EINTR {}
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async { self?.didExit(pid: p, code: code) }
        }

        onChange?()
    }

    func stop() {
        guard state == .running, pid > 0 else { return }
        stopRequested = true
        let p = pid
        write("[instance-manager] stopping process group \(p)")
        killpg(p, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.pid == p else { return }
            killpg(p, SIGKILL)
        }
    }

    func restart() {
        if state == .running {
            restartAfterExit = true
            stop()
        } else {
            start()
        }
    }

    /// Last-resort cleanup when the app quits.
    func forceKill() {
        if pid > 0 { killpg(pid, SIGKILL) }
    }

    func ensureLogFile() {
        logQueue.sync { openHandleIfNeeded() }
    }

    // MARK: - Internals

    private func didExit(pid p: pid_t, code: Int32) {
        guard pid == p else { return }
        pid = 0
        exitCode = code
        state = stopRequested ? .stopped : (code == 0 ? .exited : .failed)
        write("[instance-manager] exited with code \(code)")
        stopRequested = false
        if restartAfterExit {
            restartAfterExit = false
            start()
            return
        }
        onChange?()
    }

    private func fail(_ message: String) {
        write("[instance-manager] ERROR: \(message)")
        lastLine = message
        state = .failed
        onChange?()
    }

    private func attachReader(fd: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        src.setEventHandler { [weak self] in
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    self?.ingest(line)
                }
            } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                if !buffer.isEmpty {
                    self?.ingest(String(decoding: buffer, as: UTF8.self))
                    buffer.removeAll()
                }
                src.cancel()
            }
        }
        src.setCancelHandler { close(fd) }
        readSources.append(src)
        src.resume()
    }

    private func ingest(_ raw: String) {
        let line = raw
            .replacingOccurrences(of: Self.ansi, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        write(line)
        let shown = line.trimmingCharacters(in: .whitespaces)
        if !shown.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let before = self.health
                self.lastLine = shown
                if self.health != before {
                    self.onChange?()
                    if self.state == .running { self.onHealthChange?(self.health) }
                }
            }
        }
    }

    /// Appends a line to ~/Library/Logs/InstanceManager/<id>.log
    private func write(_ text: String) {
        logQueue.async { [weak self] in
            guard let self else { return }
            self.openHandleIfNeeded()
            let line = "\(self.stampFormatter.string(from: Date())) \(text)\n"
            try? self.logHandle?.write(contentsOf: Data(line.utf8))
        }
    }

    /// Call on logQueue only.
    private func openHandleIfNeeded() {
        if logHandle != nil { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: ConfigStore.logsDir, withIntermediateDirectories: true)
        let path = logURL.path
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 5_000_000 {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        logHandle = FileHandle(forWritingAtPath: path)
        _ = try? logHandle?.seekToEnd()
    }
}
