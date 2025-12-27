import Cocoa
import Combine

/// Monitors global keystrokes using CGEventTap
final class KeystrokeMonitor: ObservableObject {
    @Published private(set) var keystrokeCount: UInt64 = 0
    @Published private(set) var wordCount: UInt64 = 0
    @Published private(set) var isRunning = false

    // Word separator keycodes
    private static let wordSeparators: Set<Int64> = [49, 36, 76, 48]  // space, enter, return, tab

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoopThread: Thread?
    private var backgroundRunLoop: CFRunLoop?
    private let lock = NSLock()

    deinit {
        stop()
    }

    /// Start monitoring keystrokes
    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard eventTap == nil else { return }

        // Event mask for keyDown events only
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // Create the event tap
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<KeystrokeMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .keyDown {
                    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
                    let isWordSeparator = KeystrokeMonitor.wordSeparators.contains(keycode)
                    DispatchQueue.main.async {
                        monitor.keystrokeCount += 1
                        if isWordSeparator {
                            monitor.wordCount += 1
                        }
                    }
                }

                // Handle tap being disabled by system
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            // Event tap creation failed - likely missing Accessibility permission
            return
        }

        // Create run loop source
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)

        // Run on a background thread
        runLoopThread = Thread { [weak self] in
            guard let self = self, let source = self.runLoopSource else { return }

            let runLoop = CFRunLoopGetCurrent()
            self.lock.lock()
            self.backgroundRunLoop = runLoop
            self.lock.unlock()

            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)

            // Keep the run loop running
            CFRunLoopRun()
        }
        runLoopThread?.name = "KeystrokeMonitor"
        runLoopThread?.start()

        DispatchQueue.main.async {
            self.isRunning = true
        }
    }

    /// Stop monitoring keystrokes
    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard let eventTap = eventTap else { return }

        CGEvent.tapEnable(tap: eventTap, enable: false)

        // Stop the background run loop
        if let runLoop = backgroundRunLoop {
            CFRunLoopStop(runLoop)
        }

        if let thread = runLoopThread, !thread.isCancelled {
            thread.cancel()
        }

        self.eventTap = nil
        self.runLoopSource = nil
        self.runLoopThread = nil
        self.backgroundRunLoop = nil

        DispatchQueue.main.async {
            self.isRunning = false
        }
    }

    /// Reset the keystroke count
    func reset() {
        DispatchQueue.main.async {
            self.keystrokeCount = 0
        }
    }

    /// Thread-safe consume count
    func consumeCount() -> UInt64 {
        var count: UInt64 = 0
        if Thread.isMainThread {
            count = keystrokeCount
            keystrokeCount = 0
        } else {
            DispatchQueue.main.sync {
                count = self.keystrokeCount
                self.keystrokeCount = 0
            }
        }
        return count
    }
}
