import AppKit
import Carbon.HIToolbox

/// Option-1, -2 and -3 ask for the first three modes in the config's order (Profile 1,
/// Profile 2, Socials), as a click on their buttons would. A key held down clicks again every half second, so
/// holding Option-3 runs through the three warning clicks and then starts and cuts the wait.
/// Read with a key event tap, which uses the Accessibility the dock has already: macOS 15 accepts a
/// Carbon hot key with Option as its only modifier and then never delivers it. The keys reach no
/// other app.
@MainActor
final class ModeHotKeys {
    private let model: DockModel
    private var tap: CFMachPort?
    private var enabled = true
    private var held: (index: Int, timer: Timer)?
    private var swallowed: Set<Int64> = []   // keys whose press we took, so we take their release too
    private static let keys: [Int64: Int] = [Int64(kVK_ANSI_1): 0, Int64(kVK_ANSI_2): 1, Int64(kVK_ANSI_3): 2]
    nonisolated(unsafe) static weak var shared: ModeHotKeys?

    init(model: DockModel) {
        self.model = model
        ModeHotKeys.shared = self
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: hotKeyCallback, userInfo: nil)
        else { log("Option-1 to 3: no key tap (Accessibility?)"); return }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("Option-1 to 3: ready")
    }

    /// Takes Option-1 to 3, with no other modifier, and lets every other key through.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, enabled { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let index = Self.keys[code] else { return Unmanaged.passUnretained(event) }
        if type == .keyUp {
            guard swallowed.remove(code) != nil else { return Unmanaged.passUnretained(event) }
            if held?.index == index { held?.timer.invalidate(); held = nil }
            return nil
        }
        let mods = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
        // A plain press of the key: its keyUp is its own, even if an earlier one was never seen.
        guard mods == .maskAlternate else { swallowed.remove(code); return Unmanaged.passUnretained(event) }
        swallowed.insert(code)
        // The system's own key repeat is dropped: holding clicks every half second instead.
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { press(index) }
        return nil
    }

    /// The Option-1 to 3 add-in: off, the keys type their characters again.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
        if !on { held?.timer.invalidate(); held = nil; swallowed.removeAll() }
        log("Option-1 to 3: \(on ? "on" : "off")")
    }

    private func press(_ index: Int) {
        held?.timer.invalidate()
        click(index)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Option let go first: stop as soon as it is up, release or not.
                guard NSEvent.modifierFlags.contains(.option) else { self?.held?.timer.invalidate(); self?.held = nil; return }
                self?.click(index)
            }
        }
        held = (index, timer)
    }

    private func click(_ index: Int) {
        let modes = model.config.modes
        guard modes.indices.contains(index) else { return }
        log("Option-\(index + 1): \(modes[index].name)")
        model.tap(modes[index].name)
    }
}

private let hotKeyCallback: CGEventTapCallBack = { _, type, event, _ in
    MainActor.assumeIsolated { ModeHotKeys.shared?.handle(type, event) ?? Unmanaged.passUnretained(event) }
}
