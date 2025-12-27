import Foundation
import Combine
import Cocoa

/// Central coordinator for all stats data - handles local storage, iCloud sync, and CRDT merging
final class StatsRepository: ObservableObject {
    @Published private(set) var todayStats: DailyStats?
    @Published private(set) var recentStats: [DailyStats] = []
    @Published private(set) var yesterdayCount: UInt64 = 0
    @Published private(set) var sevenDayAvg: UInt64 = 0
    @Published private(set) var thirtyDayAvg: UInt64 = 0
    @Published private(set) var recordCount: UInt64 = 0
    @Published private(set) var recordDate: String = ""

    // Word stats
    @Published private(set) var yesterdayWords: UInt64 = 0
    @Published private(set) var sevenDayAvgWords: UInt64 = 0
    @Published private(set) var thirtyDayAvgWords: UInt64 = 0
    @Published private(set) var recordWords: UInt64 = 0
    @Published private(set) var recordWordsDate: String = ""

    private let localStore = LocalStore()
    private let cloudSync = iCloudSync()
    private var keystrokeMonitor: KeystrokeMonitor?
    private var statsCache: [String: DailyStats] = [:]

    private var saveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastKeystrokeCount: UInt64 = 0
    private var lastWordCount: UInt64 = 0

    init() {
        loadInitialData()
        setupSyncObserver()
    }

    deinit {
        saveTask?.cancel()
        keystrokeMonitor?.stop()
        forceSave()
    }

    /// Set up keystroke monitoring with permission check
    func setupKeystrokeMonitoring() {
        guard keystrokeMonitor == nil else { return }

        let monitor = KeystrokeMonitor()
        keystrokeMonitor = monitor

        // Monitor keystroke count changes
        monitor.$keystrokeCount
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newCount in
                guard let self = self else { return }
                let delta = newCount - self.lastKeystrokeCount
                if delta > 0 {
                    self.recordKeystrokes(delta)
                }
                self.lastKeystrokeCount = newCount
            }
            .store(in: &cancellables)

        // Monitor word count changes
        monitor.$wordCount
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newCount in
                guard let self = self else { return }
                let delta = newCount - self.lastWordCount
                if delta > 0 {
                    self.recordWords(delta)
                }
                self.lastWordCount = newCount
            }
            .store(in: &cancellables)

        // Start monitoring if we have permission
        startMonitoringIfAuthorized()
    }

    /// Check permission and start monitoring
    func startMonitoringIfAuthorized() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        if AXIsProcessTrustedWithOptions(options as CFDictionary) {
            keystrokeMonitor?.start()
        }
    }

    /// Load data from local store and iCloud
    private func loadInitialData() {
        // Load local first
        statsCache = localStore.loadAll()

        // Merge with iCloud data
        let cloudStats = cloudSync.loadAll()
        for (dateID, cloudStat) in cloudStats {
            if var localStat = statsCache[dateID] {
                localStat.merge(with: cloudStat)
                statsCache[dateID] = localStat
            } else {
                statsCache[dateID] = cloudStat
            }
        }

        updatePublishedStats()
    }

    /// Set up observer for iCloud changes from other devices
    private func setupSyncObserver() {
        cloudSync.observeChanges { [weak self] remoteStats in
            DispatchQueue.main.async {
                self?.handleRemoteChanges(remoteStats)
            }
        }
    }

    /// Handle stats received from iCloud
    private func handleRemoteChanges(_ remoteStats: [DailyStats]) {
        for remoteStat in remoteStats {
            if var localStat = statsCache[remoteStat.id] {
                localStat.merge(with: remoteStat)
                statsCache[remoteStat.id] = localStat
                localStore.save(localStat)
            } else {
                statsCache[remoteStat.id] = remoteStat
                localStore.save(remoteStat)
            }
        }
        updatePublishedStats()
    }

    /// Record a keystroke for today
    func recordKeystroke() {
        let today = DateHelpers.todayID()

        if var stats = statsCache[today] {
            stats.increment()
            statsCache[today] = stats
        } else {
            var stats = DailyStats()
            stats.increment()
            statsCache[today] = stats
        }

        updatePublishedStats()
        scheduleSave()
    }

    /// Record multiple keystrokes at once (for batching)
    func recordKeystrokes(_ count: UInt64) {
        guard count > 0 else { return }

        let today = DateHelpers.todayID()

        if var stats = statsCache[today] {
            stats.increment(by: count)
            statsCache[today] = stats
        } else {
            var stats = DailyStats()
            stats.increment(by: count)
            statsCache[today] = stats
        }

        updatePublishedStats()
        scheduleSave()
    }

    /// Record multiple words at once (for batching)
    func recordWords(_ count: UInt64) {
        guard count > 0 else { return }

        let today = DateHelpers.todayID()

        if var stats = statsCache[today] {
            stats.incrementWords(by: count)
            statsCache[today] = stats
        } else {
            var stats = DailyStats()
            stats.incrementWords(by: count)
            statsCache[today] = stats
        }

        updatePublishedStats()
        scheduleSave()
    }

    /// Debounced save to avoid excessive I/O
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            persistCurrentStats()
        }
    }

    /// Actually persist to local and cloud
    private func persistCurrentStats() {
        let today = DateHelpers.todayID()
        guard let stats = statsCache[today] else { return }
        localStore.save(stats)
        cloudSync.save(stats)
    }

    /// Update the published properties for UI
    private func updatePublishedStats() {
        let today = DateHelpers.todayID()
        todayStats = statsCache[today]

        // Get all stats sorted newest first
        let allStats = statsCache.values.sorted { $0.id > $1.id }
        recentStats = Array(allStats.prefix(7))

        // Yesterday
        let yesterday = DateHelpers.dateID(daysAgo: 1)
        yesterdayCount = statsCache[yesterday]?.totalKeystrokes ?? 0
        yesterdayWords = statsCache[yesterday]?.totalWords ?? 0

        // 7-day average (excluding today)
        let last7Days = (1...7).compactMap { statsCache[DateHelpers.dateID(daysAgo: $0)] }
        if !last7Days.isEmpty {
            let total = last7Days.reduce(UInt64(0)) { $0 + $1.totalKeystrokes }
            sevenDayAvg = total / UInt64(last7Days.count)
            let totalWords = last7Days.reduce(UInt64(0)) { $0 + $1.totalWords }
            sevenDayAvgWords = totalWords / UInt64(last7Days.count)
        } else {
            sevenDayAvg = 0
            sevenDayAvgWords = 0
        }

        // 30-day average (excluding today)
        let last30Days = (1...30).compactMap { statsCache[DateHelpers.dateID(daysAgo: $0)] }
        if !last30Days.isEmpty {
            let total = last30Days.reduce(UInt64(0)) { $0 + $1.totalKeystrokes }
            thirtyDayAvg = total / UInt64(last30Days.count)
            let totalWords = last30Days.reduce(UInt64(0)) { $0 + $1.totalWords }
            thirtyDayAvgWords = totalWords / UInt64(last30Days.count)
        } else {
            thirtyDayAvg = 0
            thirtyDayAvgWords = 0
        }

        // Record (all time high) - keystrokes
        if let record = allStats.max(by: { $0.totalKeystrokes < $1.totalKeystrokes }) {
            recordCount = record.totalKeystrokes
            recordDate = DateHelpers.shortDisplayString(from: record.id)
        }

        // Record (all time high) - words
        if let record = allStats.max(by: { $0.totalWords < $1.totalWords }) {
            recordWords = record.totalWords
            recordWordsDate = DateHelpers.shortDisplayString(from: record.id)
        }
    }

    /// Force save (call on app termination)
    func forceSave() {
        saveTask?.cancel()
        let today = DateHelpers.todayID()
        if let stats = statsCache[today] {
            localStore.save(stats)
            cloudSync.save(stats)
        }
    }

    /// Get all stats for history view
    func getAllStats() -> [DailyStats] {
        statsCache.values.sorted { $0.id > $1.id }
    }
}
