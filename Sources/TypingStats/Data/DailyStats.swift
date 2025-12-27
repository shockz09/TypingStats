import Foundation

/// Represents keystroke statistics for a single day
struct DailyStats: Identifiable, Equatable {
    /// Date identifier in YYYY-MM-DD format
    let id: String
    /// G-Counter for this day's keystrokes
    var counter: GCounter
    /// G-Counter for this day's words
    var wordCounter: GCounter
    /// When this record was first created
    let createdAt: Date
    /// Last modification time
    var modifiedAt: Date

    /// Total keystrokes across all devices for this day
    var totalKeystrokes: UInt64 {
        counter.total
    }

    /// Total words across all devices for this day
    var totalWords: UInt64 {
        wordCounter.total
    }

    init(date: Date = Date()) {
        self.id = DateHelpers.dateID(from: date)
        self.counter = GCounter()
        self.wordCounter = GCounter()
        self.createdAt = date
        self.modifiedAt = date
    }

    /// Increment the keystroke count for the current device
    mutating func increment(by amount: UInt64 = 1) {
        counter.increment(deviceID: DeviceIdentifier.current, by: amount)
        modifiedAt = Date()
    }

    /// Increment the word count for the current device
    mutating func incrementWords(by amount: UInt64 = 1) {
        wordCounter.increment(deviceID: DeviceIdentifier.current, by: amount)
        modifiedAt = Date()
    }

    /// Merge with another DailyStats (for iCloud sync)
    mutating func merge(with other: DailyStats) {
        counter.merge(with: other.counter)
        wordCounter.merge(with: other.wordCounter)
        modifiedAt = Date()
    }
}

// MARK: - Codable (backward-compatible)
extension DailyStats: Codable {
    enum CodingKeys: String, CodingKey {
        case id, counter, wordCounter, createdAt, modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        counter = try container.decode(GCounter.self, forKey: .counter)
        // Backward-compatible: old data won't have wordCounter
        wordCounter = try container.decodeIfPresent(GCounter.self, forKey: .wordCounter) ?? GCounter()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
    }
}

/// Date formatting utilities
struct DateHelpers {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    static func todayID() -> String {
        formatter.string(from: Date())
    }

    static func dateID(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from id: String) -> Date? {
        formatter.date(from: id)
    }

    /// Format date ID for display (e.g., "Dec 27")
    static func displayString(from id: String) -> String {
        guard let date = date(from: id) else { return id }
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMM d"
        return displayFormatter.string(from: date)
    }

    /// Get date ID for N days ago
    static func dateID(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return formatter.string(from: date)
    }

    /// Short display format (e.g., "12/26")
    static func shortDisplayString(from id: String) -> String {
        guard let date = date(from: id) else { return id }
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "M/d"
        return displayFormatter.string(from: date)
    }
}
