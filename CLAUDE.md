# PenguEgg — macOS Menu Bar Battery Companion

## Overview

A macOS menu bar app (like RunCat) featuring a pixel-art penguin egg that grows with your battery. The character evolves: egg → cracked egg → penguin face in shell → baby penguin standing → baby penguin walking.

---

## Project Setup

### Create Xcode Project

```
Xcode → New Project → macOS → App
- Product Name: PenguEgg
- Interface: SwiftUI (but we mainly use AppKit for the menu bar)
- Language: Swift
- Uncheck: "Create Tests"
```

### Info.plist — Menu-bar-only app (no Dock icon)

```xml
<key>LSUIElement</key>
<true/>
```

---

## File Structure

```
PenguEgg/
├── PenguEggApp.swift            # App entry, NSApplication.accessory
├── MenuBarController.swift      # NSStatusItem, menu, icon updates
├── StateManager.swift           # Battery → state mapping with hysteresis
├── AnimationManager.swift       # Frame cycling per state, transitions
├── Assets.xcassets/
│   ├── AppIcon.appiconset/
│   ├── egg_frame0.imageset/     # Egg upright
│   ├── egg_frame1.imageset/     # Egg tilted (shake)
│   ├── egg_cracked.imageset/    # Egg with cracks
│   ├── mid_frame0.imageset/     # Penguin face in shell - eyes open
│   ├── mid_frame1.imageset/     # Penguin face in shell - eyes closed
│   ├── mid_frame2.imageset/     # Penguin hiding/sinking into shell
│   ├── midhi_frame0.imageset/   # Baby penguin standing (front view)
│   ├── high_frame0.imageset/    # Baby penguin side - standing
│   └── high_frame1.imageset/    # Baby penguin side - walking
└── Info.plist
```

---

## Assets — 9 Sprites

All sprites are in `sprites/`. Transparent background, square, pixel art. Beak color is unified to orange across all frames.

| File | State | Description |
|------|-------|-------------|
| `egg_frame0.png` | LOW | Egg upright |
| `egg_frame1.png` | LOW | Egg tilted |
| `egg_cracked.png` | LOW→MID transition | Egg with cracks |
| `mid_frame0.png` | MID | Penguin face in half-shell, eyes open |
| `mid_frame1.png` | MID | Penguin face in half-shell, eyes closed |
| `mid_frame2.png` | MID | Penguin hiding/sinking into shell |
| `midhi_frame0.png` | MID→HIGH transition | Baby penguin standing (front view) |
| `high_frame0.png` | HIGH | Baby penguin side view, standing |
| `high_frame1.png` | HIGH | Baby penguin side view, walking |

### Asset Catalog — Each imageset `Contents.json`

```json
{
  "images": [
    { "filename": "SPRITENAME.png", "idiom": "universal", "scale": "1x" },
    { "filename": "SPRITENAME@2x.png", "idiom": "universal", "scale": "2x" }
  ],
  "info": { "author": "xcode", "version": 1 },
  "properties": { "template-rendering-intent": "original" }
}
```

**CRITICAL**: `"template-rendering-intent": "original"` — without this, macOS strips all color and renders monochrome.

### Sizing

- Menu bar icon: **18×18 pt**
- `_36.png` files → use as `@2x` (36×36 px)
- For `@1x`: resize full-res to 18×18 using **nearest-neighbor** (preserves pixel art)

---

## State System — 5 Visual States

```swift
enum PenguinState: String {
    case low        // 0–10%:   egg shaking
    case lowToMid   // transition: egg cracks → face appears (one-shot)
    case mid        // 11–80%:  penguin face blinking in shell
    case midToHigh  // transition: baby penguin standing (one-shot)
    case high       // 81–100%: baby penguin walking
}
```

### Battery Thresholds (with hysteresis)

| Transition | Threshold | Hysteresis |
|-----------|-----------|------------|
| LOW → MID | 13% (up) | +3% buffer |
| MID → LOW | 10% (down) | |
| MID → HIGH | 81% (up) | |
| HIGH → MID | 78% (down) | -3% buffer |

### Animation Sequences

**LOW** (loop): `egg_frame0 ↔ egg_frame1` at 0.4s — gentle shake

**LOW→MID** (one-shot, then → MID):
```
egg_frame0 → egg_frame1 → egg_frame0 → egg_cracked → egg_cracked → mid_frame0
```

**MID** (loop): `mid_frame0(×4) → mid_frame1(×2)` at 0.35s — natural blink rhythm (~2.1s cycle)

**MID hiding** (rare, ~once per minute): When the hide timer fires, play a one-shot hide sequence:
```
mid_frame1 → mid_frame2 → mid_frame2 → mid_frame2 → mid_frame1 → mid_frame0
```
The penguin closes eyes, sinks into the shell, peeks for a moment, then pops back up. After the sequence, resume normal blink loop. A separate `hideTimer` fires every ~60 seconds (± random jitter 10–20s) while in MID state.

**MID→HIGH** (one-shot, then → HIGH):
```
midhi_frame0 → midhi_frame0 → midhi_frame0 → high_frame0
```

**HIGH** (loop): `high_frame0 ↔ high_frame1` at 0.3s — waddle walk

---

## Implementation

### 1. `PenguEggApp.swift`

```swift
import SwiftUI

@main
struct PenguEggApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        menuBarController = MenuBarController()
    }
}
```

### 2. `StateManager.swift`

```swift
import Foundation
import IOKit.ps

enum PenguinState: String {
    case low
    case lowToMid
    case mid
    case midToHigh
    case high
}

class StateManager: ObservableObject {
    @Published private(set) var currentState: PenguinState = .mid
    @Published private(set) var batteryLevel: Int = 50
    @Published private(set) var isCharging: Bool = false

    private var timer: Timer?

    private let lowToMidThreshold = 13
    private let midToLowThreshold = 10
    private let midToHighThreshold = 81
    private let highToMidThreshold = 78

    init() {
        updateBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateBattery()
        }
    }

    deinit { timer?.invalidate() }

    func updateBattery() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]

        guard let source = sources.first,
              let info = IOPSGetPowerSourceDescription(snapshot, source)
                .takeUnretainedValue() as? [String: Any],
              let capacity = info[kIOPSCurrentCapacityKey] as? Int else {
            // Desktop Mac fallback
            batteryLevel = 100
            currentState = .high
            return
        }

        batteryLevel = capacity
        isCharging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

        let newState: PenguinState
        switch currentState {
        case .low:
            newState = capacity >= lowToMidThreshold ? .lowToMid : .low
        case .lowToMid:
            newState = .lowToMid  // don't interrupt transition
        case .mid:
            if capacity <= midToLowThreshold {
                newState = .low
            } else if capacity >= midToHighThreshold {
                newState = .midToHigh
            } else {
                newState = .mid
            }
        case .midToHigh:
            newState = .midToHigh  // don't interrupt transition
        case .high:
            newState = capacity <= highToMidThreshold ? .mid : .high
        }

        if newState != currentState {
            currentState = newState
        }
    }

    /// Called by AnimationManager when a transition animation finishes
    func transitionCompleted(from state: PenguinState) {
        switch state {
        case .lowToMid:  currentState = .mid
        case .midToHigh: currentState = .high
        default: break
        }
    }
}
```

### 3. `AnimationManager.swift`

```swift
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
    private var isHiding = false

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

    private func advanceFrame() {
        guard !activeFrames.isEmpty else { return }

        let frameName = activeFrames[currentFrameIndex]
        let image = NSImage(named: frameName)
        image?.isTemplate = false
        image?.size = NSSize(width: 18, height: 18)
        onFrameUpdate?(image)

        currentFrameIndex += 1

        if currentFrameIndex >= activeFrames.count {
            if isTransition {
                isTransition = false
                onTransitionComplete?(state)
            } else if isHiding {
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
```

### 4. `MenuBarController.swift`

```swift
import AppKit
import Combine

class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateManager = StateManager()
    private let animationManager = AnimationManager()
    private var cancellables = Set<AnyCancellable>()

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.image = NSImage(named: "egg_frame0")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = false
        }

        setupMenu()

        animationManager.onFrameUpdate = { [weak self] image in
            DispatchQueue.main.async {
                self?.statusItem.button?.image = image
            }
        }

        animationManager.onTransitionComplete = { [weak self] fromState in
            DispatchQueue.main.async {
                self?.stateManager.transitionCompleted(from: fromState)
            }
        }

        stateManager.$currentState
            .removeDuplicates()
            .sink { [weak self] newState in
                self?.animationManager.setState(newState)
            }
            .store(in: &cancellables)

        animationManager.start(with: stateManager.currentState)
    }

    private func setupMenu() {
        let menu = NSMenu()

        let batteryItem = NSMenuItem(
            title: "🔋 \(stateManager.batteryLevel)%",
            action: nil, keyEquivalent: ""
        )
        batteryItem.tag = 100
        menu.addItem(batteryItem)

        let chargingItem = NSMenuItem(
            title: stateManager.isCharging ? "⚡ Charging" : "🔌 On Battery",
            action: nil, keyEquivalent: ""
        )
        chargingItem.tag = 101
        menu.addItem(chargingItem)

        menu.addItem(NSMenuItem.separator())

        let stateItem = NSMenuItem(
            title: stateLabel(for: stateManager.currentState),
            action: nil, keyEquivalent: ""
        )
        stateItem.tag = 102
        menu.addItem(stateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit PenguEgg",
            action: #selector(quitApp), keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    private func stateLabel(for state: PenguinState) -> String {
        switch state {
        case .low:       return "🥚 Egg is resting..."
        case .lowToMid:  return "🥚💥 Egg is hatching!"
        case .mid:       return "🐣 Penguin peeking out!"
        case .midToHigh: return "🐣➡️🐧 Penguin emerging!"
        case .high:      return "🐧 Penguin is exploring!"
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        stateManager.updateBattery()
        menu.item(withTag: 100)?.title = "🔋 \(stateManager.batteryLevel)%"
        menu.item(withTag: 101)?.title = stateManager.isCharging
            ? "⚡ Charging" : "🔌 On Battery"
        menu.item(withTag: 102)?.title = stateLabel(for: stateManager.currentState)
    }
}
```

---

## Key Design Decisions

### `isTemplate = false`
macOS renders menu bar icons as monochrome templates by default. We set `isTemplate = false` on every frame + `"template-rendering-intent": "original"` in each imageset to keep full color.

### Desktop Mac Fallback
No battery → `IOPSCopyPowerSourcesList` returns empty. Defaults to `batteryLevel = 100, state = .high` so the penguin walks.

### Hysteresis (3% buffer)
Prevents rapid state switching when battery hovers near a threshold (e.g., 10% ± 1%).

### Transition Animations
One-shot sequences that play once when crossing thresholds, then hand off to the target state's idle loop. The `AnimationManager` fires `onTransitionComplete` → `StateManager.transitionCompleted()` to advance.

### MID Blink Rhythm
Frame array `[open×4, closed×2]` at 0.35s = eyes open ~1.4s, closed ~0.7s per cycle. Natural and not distracting.

### MID Hiding Behavior
Every ~60 seconds (± 10s random jitter), the penguin sinks into its shell for a moment. A separate one-shot `hideTimer` fires, interrupts the blink loop with a 6-frame hide sequence, then resumes normal blinking and reschedules. The jitter prevents it from feeling mechanical. Only active while in MID state — invalidated on state change.

### CPU Usage < 0.1%
Timer-based NSImage swap only. No continuous rendering, no Metal/GL, no CADisplayLink.

---

## Build & Run

1. Open `PenguEgg.xcodeproj`
2. Add all 9 imagesets to `Assets.xcassets` with correct `Contents.json`
3. Signing: "Sign to Run Locally"
4. Run → penguin appears in menu bar
5. Click → see battery percentage

---

## Debug / Testing

```swift
#if DEBUG
extension StateManager {
    func debugSetState(_ state: PenguinState) {
        currentState = state
        switch state {
        case .low:       batteryLevel = 5
        case .lowToMid:  batteryLevel = 13
        case .mid:       batteryLevel = 50
        case .midToHigh: batteryLevel = 81
        case .high:      batteryLevel = 95
        }
    }
}
#endif
```

---

## Future (Out of scope for v1)

- Charging animation (sparkle overlay)
- Preferences window (thresholds, speed)
- Login item (`SMAppService.register()`)
- Sound effects (optional chirp on state change)
