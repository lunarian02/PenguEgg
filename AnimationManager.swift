import AppKit

class AnimationManager {
    // ── Frame sequences ──
    private let lowFrames = ["egg_frame0", "egg_frame1"]

    private let lowToMidFrames = [
        "egg_frame0", "egg_frame1", "egg_frame0",
        "egg_cracked", "egg_cracked", "mid_frame0"
    ]

    // 4 open + 2 closed = natural blink (~2.1s at 0.35s interval)
    private let midFrames = [
        "mid_frame0", "mid_frame0", "mid_frame0", "mid_frame0",
        "mid_frame1", "mid_frame1"
    ]

    // Hide sequence: close eyes → sink → hold → peek → pop back
    private let midHideFrames = [
        "mid_frame1", "mid_frame2", "mid_frame2", "mid_frame2",
        "mid_frame1", "mid_frame0"
    ]

    private let midToHighFrames = [
        "midhi_frame0", "midhi_frame0",
        "midhi_frame0", "high_frame0"
    ]

    private let highFrames = ["high_frame0", "high_frame1"]

    // ── State ──
    private var currentFrameIndex = 0
    private var activeFrames: [String] = []
    private var timer: Timer?
    private var hideTimer: Timer?
    private var state: PenguinState = .mid
    private var isTransition = false
    private var isHiding = false  // mid-state hide sequence in progress

    // ── Callbacks ──
    var onFrameUpdate: ((NSImage?) -> Void)?
    var onTransitionComplete: ((PenguinState) -> Void)?

    func setState(_ newState: PenguinState) {
        guard newState != state else { return }
        state = newState
        currentFrameIndex = 0
        isHiding = false
        configureForState()
        startTimer()
        manageHideTimer()
    }

    func start(with state: PenguinState) {
        self.state = state
        configureForState()
        startTimer()
        manageHideTimer()
    }

    private func configureForState() {
        switch state {
        case .low:
            activeFrames = lowFrames
            isTransition = false
        case .lowToMid:
            activeFrames = lowToMidFrames
            isTransition = true
        case .mid:
            activeFrames = midFrames
            isTransition = false
        case .midToHigh:
            activeFrames = midToHighFrames
            isTransition = true
        case .high:
            activeFrames = highFrames
            isTransition = false
        }
        currentFrameIndex = 0
    }

    // ── Hide timer: only active during MID state ──
    private func manageHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil

        guard state == .mid else { return }
        scheduleNextHide()
    }

    private func scheduleNextHide() {
        // 50–70 seconds (60 ± 10s jitter)
        let delay = TimeInterval.random(in: 50...70)
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) {
            [weak self] _ in
            self?.triggerHide()
        }
    }

    private func triggerHide() {
        guard state == .mid, !isHiding else { return }
        isHiding = true
        activeFrames = midHideFrames
        currentFrameIndex = 0
        // Timer interval stays the same (0.35s)
    }

    private func startTimer() {
        timer?.invalidate()

        let interval: TimeInterval
        switch state {
        case .low:       interval = 0.4
        case .lowToMid:  interval = 0.35
        case .mid:       interval = 0.35
        case .midToHigh: interval = 0.3
        case .high:      interval = 0.3
        }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in self?.advanceFrame()
        }
        advanceFrame()
    }

    private func makeMenuBarImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png",
                                        subdirectory: "PNGs"),
              let image = NSImage(contentsOf: url) else { return nil }

        // Don't redraw - just set the size and let macOS handle it
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = false
        return image
    }

    private func advanceFrame() {
        guard !activeFrames.isEmpty else { return }

        let frameName = activeFrames[currentFrameIndex]
        let image = makeMenuBarImage(named: frameName)
        onFrameUpdate?(image)

        currentFrameIndex += 1

        if currentFrameIndex >= activeFrames.count {
            if isTransition {
                isTransition = false
                onTransitionComplete?(state)
            } else if isHiding {
                // Hide sequence done → return to normal blink loop
                isHiding = false
                activeFrames = midFrames
                currentFrameIndex = 0
                scheduleNextHide()
            } else {
                currentFrameIndex = 0
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hideTimer?.invalidate()
        hideTimer = nil
    }
}
