import SwiftUI
import Charts

enum TimeRange: String, CaseIterable {
    case week = "7 days"
    case month = "30 days"
    case twoMonths = "60 days"

    var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .twoMonths: return 60
        }
    }
}

struct HistoryView: View {
    let allStats: [DailyStats]
    let displayMode: DisplayMode
    @State private var selectedRange: TimeRange = .month

    private var filteredStats: [DailyStats] {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -selectedRange.days, to: Date()) ?? Date()
        let cutoffID = DateHelpers.dateID(from: cutoffDate)
        return allStats.filter { $0.id >= cutoffID }.sorted { $0.id < $1.id }
    }

    private func getCount(for stats: DailyStats?) -> UInt64 {
        guard let stats = stats else { return 0 }
        return displayMode == .keystrokes ? stats.totalKeystrokes : stats.totalWords
    }

    private var chartData: [ChartDataPoint] {
        // Create data points for all days in range, even if no data
        var points: [ChartDataPoint] = []
        for i in (0..<selectedRange.days).reversed() {
            let dateID = DateHelpers.dateID(daysAgo: i)
            let count = getCount(for: allStats.first(where: { $0.id == dateID }))
            if let date = DateHelpers.date(from: dateID) {
                points.append(ChartDataPoint(date: date, count: count, dateID: dateID))
            }
        }
        return points
    }

    private var listStats: [(dateID: String, count: UInt64)] {
        // Show all days in selected range, with 0 for missing days
        (0..<selectedRange.days).map { i in
            let dateID = DateHelpers.dateID(daysAgo: i)
            let count = getCount(for: allStats.first(where: { $0.id == dateID }))
            return (dateID: dateID, count: count)
        }
    }

    private var maxCount: UInt64 {
        max(chartData.map(\.count).max() ?? 0, 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with picker
            HStack {
                Text(displayMode == .keystrokes ? "Keystroke History" : "Word History")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Picker("", selection: $selectedRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Chart
            Chart(chartData) { point in
                BarMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value(displayMode == .keystrokes ? "Keystrokes" : "Words", point.count)
                )
                .foregroundStyle(Color.accentColor)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: xAxisStride)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                        .foregroundStyle(Color.gray.opacity(0.3))
                    AxisValueLabel(format: .dateTime.month().day())
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                        .foregroundStyle(Color.gray.opacity(0.3))
                    AxisValueLabel()
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartYScale(domain: 0...Int(maxCount * 11 / 10)) // Add 10% padding
            .frame(height: 250)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            // List of daily stats
            List(listStats, id: \.dateID) { item in
                HStack {
                    Text(formatFullDate(item.dateID))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(formatNumber(item.count))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
        }
        .frame(width: 550, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var xAxisStride: Int {
        switch selectedRange {
        case .week: return 1
        case .month: return 4
        case .twoMonths: return 8
        }
    }

    private func formatFullDate(_ dateID: String) -> String {
        guard let date = DateHelpers.date(from: dateID) else { return dateID }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private func formatNumber(_ number: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}

struct ChartDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let count: UInt64
    let dateID: String
}

final class HistoryWindowController {
    private var window: NSWindow?
    private var hostingController: NSHostingController<HistoryView>?
    private var closeObserver: NSObjectProtocol?

    deinit {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func show(stats: [DailyStats], displayMode: DisplayMode) {
        // Update existing window if open
        if let existingWindow = window {
            hostingController?.rootView = HistoryView(allStats: stats, displayMode: displayMode)
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create new window
        let historyView = HistoryView(allStats: stats, displayMode: displayMode)
        let hosting = NSHostingController(rootView: historyView)
        hostingController = hosting

        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Typing Stats History"
        newWindow.styleMask = [.titled, .closable, .miniaturizable]
        newWindow.setContentSize(NSSize(width: 550, height: 500))

        // Position window to the right side of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = newWindow.frame
            let x = screenFrame.maxX - windowFrame.width - 80  // 80px from right edge
            let y = screenFrame.maxY - windowFrame.height - 50  // Near top
            newWindow.setFrameOrigin(NSPoint(x: x, y: y))
        }

        newWindow.isReleasedWhenClosed = false

        // Clear old observer if any
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // Track window close to clear references
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow,
            queue: .main
        ) { [weak self] _ in
            self?.window = nil
            self?.hostingController = nil
        }

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        window?.close()
        window = nil
        hostingController = nil
    }
}
