import Cocoa
import Combine

/// Monitors global keystrokes using CGEventTap
final class KeystrokeMonitor: ObservableObject {
    @Published private(set) var keystrokeCount: UInt64 = 0
    @Published private(set) var wordCount: UInt64 = 0
    @Published private(set) var isRunning = false

    // Word separator keycodes
    private static let wordSeparators: Set<Int64> = [49, 36, 76, 48]  // space, enter, return, tab

    // Keys to ignore for word counting (don't affect word state)
    private static let ignoredKeys: Set<Int64> = [
        51,  // delete (backspace)
        117, // forward delete
        123, 124, 125, 126  // arrows: left, right, down, up
    ]

    // Word counting state - true means last key was a separator (or start of session)
    private var lastWasSeparator = true

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

                    // Ignore navigation/editing keys for word counting
                    let isIgnored = KeystrokeMonitor.ignoredKeys.contains(keycode)
                    let isSeparator = KeystrokeMonitor.wordSeparators.contains(keycode)

                    // Thread-safe state check and update
                    monitor.lock.lock()
                    let shouldCountWord = !isIgnored && !isSeparator && monitor.lastWasSeparator
                    if !isIgnored {
                        monitor.lastWasSeparator = isSeparator
                    }
                    monitor.lock.unlock()

                    DispatchQueue.main.async {
                        monitor.keystrokeCount += 1
                        if shouldCountWord {
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

}
