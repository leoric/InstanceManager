# Instance Manager (menu bar)

Native macOS menu bar app: click the icon to see the status of every configured process.

## Build

Requires Xcode / Command Line Tools (Swift 5.9+) and macOS 13+.

    ./build.sh
    open build/InstanceManager.app

## Settings

Menu → **Settings…** opens a window where you can add, remove, reorder and edit entries
(name, kind, working directory, command / file path) with folder and file pickers.
**Save & Apply** writes the config and restarts all managed processes.

On first launch `config.json` is created from `config.example.json` (bundled into the app by `build.sh`), which contains two examples (a `ping 1.1.1.1` process and a read-only watch on `/var/log/install.log`); edit or remove them in Settings.
The config is stored as JSON at `~/Library/Application Support/InstanceManager/config.json`
(an older `instance-manager.json` or `ProcMon/procmon.json` is migrated automatically on first launch; **Open Config File** opens it if you prefer editing by hand).

## Menu

- One row per entry: colored dot, name, status
  (green running, gray stopped/exited, red failed, blue watched file).
  Status and uptime refresh every second while the menu is open.
- Health: if the last output line of a running process contains `error` (case-insensitive) the dot is red and the status reads "error"; `warning` makes it yellow. If both words appear in the line, the one that comes first wins. The menu bar icon reflects running processes only: red if any has an error, yellow if any has a warning. Stopped, exited or failed processes do not affect it.
- Notifications: when a running process's last line starts containing `error` you get a notification with sound (kept in Notification Center until dismissed); `warning` gives a quiet one. Clicking it opens that instance's log. Repeats of the same level for the same process are suppressed for 60 s. For notifications that stay on screen until you close them, set System Settings → Notifications → Instance Manager → Alert style to **Alerts**.
- Per-entry submenu: last output line, Start / Stop / Restart, Open Log.
- Start All / Stop All, Settings, config/log shortcuts, Launch at Login, Quit.
- The menu bar icon shows `running/total` and turns red if something failed.

## Behavior

- Managed processes start with the app and are stopped on quit
  (SIGTERM to the process group, SIGKILL after 4 s).
- Output goes to `~/Library/Logs/InstanceManager/<id>.log` (rotated at 5 MB on launch).
- Commands run via `/bin/zsh -l -c`, so PATH comes from your login shell (`.zprofile`).
  If a tool you launch (e.g. `python`) is only set up in `.zshrc`, move that PATH setup to `.zprofile`.
- File entries (`"managed": false`) are read-only; the menu shows when the file was last updated.
