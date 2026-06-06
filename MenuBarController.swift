import AppKit
import Combine

class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let stateManager = StateManager()
    private let animationManager = AnimationManager()
    private var cancellables = Set<AnyCancellable>()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.imageScaling = .scaleProportionallyUpOrDown

        setupMenu()

        animationManager.onFrameUpdate = { [weak self] image in
            self?.statusItem.button?.image = image
        }

        animationManager.onTransitionComplete = { [weak self] fromState in
            self?.stateManager.transitionCompleted(from: fromState)
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

        let chargingItem = NSMenuItem(title: "⚡ Charging", action: nil, keyEquivalent: "")
        chargingItem.tag = 101
        chargingItem.isHidden = !stateManager.isCharging
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
        menu.item(withTag: 101)?.isHidden = !stateManager.isCharging
        menu.item(withTag: 101)?.title = "⚡ Charging"
        menu.item(withTag: 102)?.title = stateLabel(for: stateManager.currentState)
    }
}
