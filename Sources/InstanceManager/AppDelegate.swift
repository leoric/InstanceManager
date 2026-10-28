import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var sources: [Source] = []
    private var procs: [String: ManagedProcess] = [:]
    private var configError: String?

    private var liveItems: [String: NSMenuItem] = [:]
    private var headerItem: NSMenuItem?
    private var tick: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var settingsWindow: NSWindow?
    private var lastNotified: [String: Date] = [:]
    private var iconLevel = -1   // 0 ok, 1 warning, 2 error; -1 = not set yet

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "instance-manager"   // fresh saved position/visibility slot
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
        }
        menu.delegate = self
        statusItem.menu = menu        // left click (and right click) opens the menu

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }

        loadConfig()
        startAll()
        updateButton()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if procs.values.allSatisfy({ $0.state != .running }) { return .terminateNow }
        stopAll { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        procs.values.forEach { $0.forceKill() }
    }

    /// Menu-bar-only apps have no main menu, so Cmd+C / Cmd+V / Cmd+Z
    /// would not work in the settings window's text fields without this.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Config / processes

    private func loadConfig() {
        ConfigStore.ensureConfigExists()
        do {
            let data = try Data(contentsOf: ConfigStore.configURL)
            let cfg = try JSONDecoder().decode(Config.self, from: data)
            sources = cfg.processes
            procs = [:]
            for s in sources where s.managed {
                let p = ManagedProcess(source: s)
                p.onChange = { [weak self] in self?.stateChanged() }
                p.onHealthChange = { [weak self, weak p] health in
                    if let p { self?.notify(p, health) }
                }
                procs[s.id] = p
            }
            configError = nil
        } catch {
            sources = []
            procs = [:]
            configError = error.localizedDescription
        }
    }

    private func startAll() { procs.values.forEach { $0.start() } }

    private func stopAll(then completion: (() -> Void)? = nil) {
        procs.values.forEach { $0.stop() }
        guard let completion else { return }
        let deadline = Date().addingTimeInterval(6)
        func poll() {
            if procs.values.allSatisfy({ $0.state != .running }) || Date() > deadline {
                completion()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        poll()
    }

    private func stateChanged() {
        updateButton()
        refreshLive()
    }

    // MARK: - Status bar button

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let running = procs.values.filter { $0.state == .running }.count
        let failed = procs.values.contains {
            $0.state == .failed || ($0.state == .running && $0.health == .error)
        }
        let warned = procs.values.contains { $0.state == .running && $0.health == .warning }
        // Never touch contentTintColor: it also tints the title and, once set, the
        // button stops adapting to the light/dark menu bar. Swap the icon instead.
        let level = failed ? 2 : (warned ? 1 : 0)
        if level != iconLevel {
            iconLevel = level
            button.image = statusImage(level == 2 ? .systemRed : (level == 1 ? .systemYellow : nil))
        }
        let prefix = button.image == nil ? "PM" : ""
        button.title = procs.isEmpty ? prefix : "\(prefix) \(running)/\(procs.count)"
    }

    /// nil color -> adaptive template icon; otherwise a colored (non-template) icon.
    private func statusImage(_ color: NSColor?) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Instance Manager") else {
            return nil
        }
        if let color {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [color])
            let img = base.withSymbolConfiguration(cfg)
            img?.isTemplate = false
            return img
        }
        base.isTemplate = true
        return base
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    func menuWillOpen(_ menu: NSMenu) {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshLive() }
        RunLoop.main.add(t, forMode: .common)   // .common so it keeps ticking while the menu is open
        tick = t
    }

    func menuDidClose(_ menu: NSMenu) {
        tick?.invalidate()
        tick = nil
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        liveItems.removeAll()

        let header = item("", nil)
        headerItem = header
        menu.addItem(header)
        menu.addItem(.separator())

        if let err = configError {
            menu.addItem(item("Config error: \(err)", nil))
        } else if sources.isEmpty {
            menu.addItem(item("No processes configured — open Settings…", nil))
        }

        for src in sources {
            let row = NSMenuItem(title: src.name, action: nil, keyEquivalent: "")
            row.submenu = buildSubmenu(for: src)
            liveItems[src.id] = row
            menu.addItem(row)
        }
        refreshLive()

        menu.addItem(.separator())
        menu.addItem(item("Start All", #selector(startAllAction)))
        menu.addItem(item("Stop All", #selector(stopAllAction)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Open Config File", #selector(openConfig)))
        menu.addItem(item("Reload Config (restarts all)", #selector(reloadConfig)))
        menu.addItem(item("Open Logs Folder", #selector(openLogsFolder)))
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Instance Manager", #selector(quit), key: "q"))
    }

    private func buildSubmenu(for src: Source) -> NSMenu {
        let sub = NSMenu()
        if let p = procs[src.id] {
            if !p.lastLine.isEmpty {
                sub.addItem(item("› " + truncate(p.lastLine, 80), nil))
                sub.addItem(.separator())
            }
            sub.addItem(item("Start", #selector(startProc(_:)), id: src.id))
            sub.addItem(item("Stop", #selector(stopProc(_:)), id: src.id))
            sub.addItem(item("Restart", #selector(restartProc(_:)), id: src.id))
            sub.addItem(.separator())
        }
        sub.addItem(item("Open Log", #selector(openLog(_:)), id: src.id))
        return sub
    }

    private func item(_ title: String, _ action: Selector?, key: String = "", id: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.representedObject = id
        return i
    }

    /// Updates titles/colors in place — works while the menu is open.
    private func refreshLive() {
        let running = procs.values.filter { $0.state == .running }.count
        headerItem?.title = "Instance Manager — \(running) of \(procs.count) running"
        for src in sources {
            guard let row = liveItems[src.id] else { continue }
            let (text, color) = describe(src)
            let s = NSMutableAttributedString(string: src.name)
            s.append(NSAttributedString(
                string: "   \(text)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            row.attributedTitle = s
            row.image = dot(color)
        }
    }

    private func describe(_ src: Source) -> (String, NSColor) {
        if let p = procs[src.id] {
            switch p.state {
            case .running:
                let up = duration(p.uptime ?? 0)
                switch p.health {
                case .error: return ("error · \(up)", .systemRed)
                case .warning: return ("warning · \(up)", .systemYellow)
                case .ok: return ("running · \(up)", .systemGreen)
                }
            case .stopped:
                return ("stopped", .systemGray)
            case .exited:
                return ("exited (code \(p.exitCode ?? 0))", .systemGray)
            case .failed:
                return ("failed (code \(p.exitCode.map(String.init) ?? "—"))", .systemRed)
            }
        }
        let path = expandPath(src.path ?? "")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let d = attrs[.modificationDate] as? Date {
            let age = Date().timeIntervalSince(d)
            return ("file · updated \(age < 5 ? "just now" : duration(age) + " ago")", .systemBlue)
        }
        return ("file not found", .systemOrange)
    }

    private func dot(_ color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    private func duration(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    // MARK: - Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let id = menuItem.representedObject as? String, let p = procs[id] else { return true }
        switch menuItem.action {
        case #selector(startProc(_:)): return p.state != .running
        case #selector(stopProc(_:)): return p.state == .running
        default: return true
        }
    }

    // MARK: - Actions

    private func proc(_ sender: NSMenuItem) -> ManagedProcess? {
        (sender.representedObject as? String).flatMap { procs[$0] }
    }

    @objc private func startProc(_ sender: NSMenuItem) { proc(sender)?.start() }
    @objc private func stopProc(_ sender: NSMenuItem) { proc(sender)?.stop() }
    @objc private func restartProc(_ sender: NSMenuItem) { proc(sender)?.restart() }

    @objc private func openLog(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let src = sources.first(where: { $0.id == id }) else { return }
        let url: URL
        if let p = procs[id] {
            p.ensureLogFile()
            url = p.logURL
        } else {
            url = URL(fileURLWithPath: expandPath(src.path ?? ""))
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func startAllAction() { startAll() }
    @objc private func stopAllAction() { stopAll() }

    @objc private func openConfig() {
        ConfigStore.ensureConfigExists()
        NSWorkspace.shared.open(ConfigStore.configURL)
    }

    @objc private func reloadConfig() {
        stopAll { [weak self] in
            self?.loadConfig()
            self?.startAll()
            self?.updateButton()
        }
    }

    @objc private func openLogsFolder() {
        try? FileManager.default.createDirectory(at: ConfigStore.logsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ConfigStore.logsDir)
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Notifications

    /// ERROR -> notification with sound that stays in Notification Center until dismissed;
    /// WARNING -> quiet notification. Same process + level replaces the previous one,
    /// and repeats within 60 s are suppressed.
    private func notify(_ p: ManagedProcess, _ health: Health) {
        guard health != .ok else { return }
        let level = health == .error ? "error" : "warning"
        let key = "\(p.source.id)-\(level)"
        if let t = lastNotified[key], Date().timeIntervalSince(t) < 60 { return }
        lastNotified[key] = Date()

        let c = UNMutableNotificationContent()
        c.title = "\(p.source.name): \(level.uppercased())"
        c.body = truncate(p.lastLine, 200)
        c.threadIdentifier = p.source.id
        c.userInfo = ["id": p.source.id]
        if health == .error { c.sound = .default }
        let req = UNNotificationRequest(identifier: "im-\(key)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // Show banners even if the app is considered frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // Clicking a notification opens that instance's log.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["id"] as? String
        DispatchQueue.main.async { [weak self] in
            if let id, let p = self?.procs[id] {
                p.ensureLogFile()
                NSWorkspace.shared.open(p.logURL)
            }
        }
        completionHandler()
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let model = SettingsModel(sources: sources)
        let view = SettingsView(
            model: model,
            onSave: { [weak self] list in self?.saveSources(list) ?? false },
            onClose: { [weak self] in self?.settingsWindow?.close() }
        )
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "Instance Manager Settings"
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 780, height: 480))
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { [weak self] _ in self?.settingsWindow = nil }
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Writes the config JSON and restarts everything with the new settings.
    private func saveSources(_ list: [Source]) -> Bool {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try enc.encode(Config(processes: list))
            try FileManager.default.createDirectory(at: ConfigStore.supportDir, withIntermediateDirectories: true)
            try data.write(to: ConfigStore.configURL, options: .atomic)
            reloadConfig()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }
}
