import Foundation
import Combine
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
