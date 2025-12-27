import SwiftUI
import Combine
import ServiceManagement

@main
struct TypingStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Display Mode
enum DisplayMode: String {
    case keystrokes
    case words
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemManager: StatusItemManager!
    private var repository: StatsRepository!
    private var permissionManager: PermissionManager!
    private var historyWindowController = HistoryWindowController()
    private var cancellables = Set<AnyCancellable>()

    private var displayMode: DisplayMode {
        get {
            DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "keystrokes") ?? .keystrokes
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "displayMode")
            updateStatusItemForMode()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize managers
        repository = StatsRepository()
        permissionManager = PermissionManager()
        statusItemManager = StatusItemManager()

        // Create status item with click handler
        statusItemManager.createStatusItem { [weak self] in
            self?.showMenu()
        }

        // Update status item when stats change
        repository.$todayStats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemForMode()
            }
            .store(in: &cancellables)

        // Start monitoring if already authorized
        permissionManager.$isAuthorized
            .receive(on: DispatchQueue.main)
            .sink { [weak self] authorized in
                if authorized {
                    self?.repository.setupKeystrokeMonitoring()
                }
            }
            .store(in: &cancellables)

        // Hide dock icon (menubar-only app)
        NSApp.setActivationPolicy(.accessory)
    }

    private func updateStatusItemForMode() {
        let count: Int
        switch displayMode {
        case .keystrokes:
            count = Int(repository.todayStats?.totalKeystrokes ?? 0)
        case .words:
            count = Int(repository.todayStats?.totalWords ?? 0)
        }
        statusItemManager.updateCount(count)
    }

    private func showMenu() {
        guard let button = statusItemManager.statusItem?.button else { return }

        let menu = NSMenu()

        // Check if we have permission
        if permissionManager.isAuthorized {
            // Stats section - show words or keystrokes based on mode
            let (today, yesterday, avg7, avg30, record, recordDateStr) = statsForCurrentMode()

            let todayItem = NSMenuItem(title: "Today: \(formatNumber(today))", action: nil, keyEquivalent: "")
            todayItem.isEnabled = false
            menu.addItem(todayItem)

            let yesterdayItem = NSMenuItem(title: "Yesterday: \(formatNumber(yesterday))", action: nil, keyEquivalent: "")
            yesterdayItem.isEnabled = false
            menu.addItem(yesterdayItem)

            let avg7Item = NSMenuItem(title: "7-day avg: \(formatNumber(avg7))", action: nil, keyEquivalent: "")
            avg7Item.isEnabled = false
            menu.addItem(avg7Item)

            let avg30Item = NSMenuItem(title: "30-day avg: \(formatNumber(avg30))", action: nil, keyEquivalent: "")
            avg30Item.isEnabled = false
            menu.addItem(avg30Item)

            if record > 0 {
                let recordItem = NSMenuItem(title: "Record: \(formatNumber(record)) (\(recordDateStr))", action: nil, keyEquivalent: "")
                recordItem.isEnabled = false
                menu.addItem(recordItem)
            }
        } else {
            let permItem = NSMenuItem(title: "Permission Required", action: #selector(grantPermission), keyEquivalent: "")
            permItem.target = self
            menu.addItem(permItem)
        }

        menu.addItem(NSMenuItem.separator())

        // View History
        let historyItem = NSMenuItem(title: "View History...", action: #selector(viewHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        // Display Mode Toggle
        let modeTitle = displayMode == .keystrokes ? "Show Words" : "Show Keystrokes"
        let modeItem = NSMenuItem(title: modeTitle, action: #selector(toggleDisplayMode), keyEquivalent: "")
        modeItem.target = self
        menu.addItem(modeItem)

        // Start at Login
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isStartAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Show menu
        statusItemManager.statusItem?.menu = menu
        button.performClick(nil)
        statusItemManager.statusItem?.menu = nil
    }

    private func formatNumber(_ number: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func statsForCurrentMode() -> (today: UInt64, yesterday: UInt64, avg7: UInt64, avg30: UInt64, record: UInt64, recordDate: String) {
        switch displayMode {
        case .keystrokes:
            return (
                repository.todayStats?.totalKeystrokes ?? 0,
                repository.yesterdayCount,
                repository.sevenDayAvg,
                repository.thirtyDayAvg,
                repository.recordCount,
                repository.recordDate
            )
        case .words:
            return (
                repository.todayStats?.totalWords ?? 0,
                repository.yesterdayWords,
                repository.sevenDayAvgWords,
                repository.thirtyDayAvgWords,
                repository.recordWords,
                repository.recordWordsDate
            )
        }
    }

    @objc private func toggleDisplayMode() {
        displayMode = displayMode == .keystrokes ? .words : .keystrokes
    }

    @objc private func grantPermission() {
        permissionManager.requestAuthorization()
    }

    @objc private func viewHistory() {
        historyWindowController.show(stats: repository.getAllStats(), displayMode: displayMode)
    }

    @objc private func toggleStartAtLogin() {
        let newValue = !isStartAtLoginEnabled()
        setStartAtLogin(enabled: newValue)
    }

    private func isStartAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func setStartAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Login item registration failed - user can retry
            }
        }
    }

    @objc private func quit() {
        repository.forceSave()
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        repository.forceSave()
    }
}
