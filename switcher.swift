// Cmd-Tab for the current mode: the dock's own switcher, listing only the current mode's apps and
// the shared ones, most recent first. macOS gives no way to filter its own switcher, so the dock
// turns it off through a private call (CGSSetSymbolicHotKeyEnabled, as AltTab does) and catches
// Cmd-Tab with an event tap. That switch outlives the process, so when the dock stops (quit,
// SIGTERM and the like, a crash) it turns macOS's switcher back on, and so does a start that finds
// it left off. Only ever when the dock itself turned it off: AltTab turns it off too.

import AppKit
import SwiftUI

/// The private call, looked up when the dock starts rather than linked: were a later macOS to drop
/// or rename it, a linked call would stop the whole dock from launching, while a looked-up one
/// only leaves macOS's own switcher in place (see `canTurnOffNativeCommandTab`).
typealias SymbolicHotKeyEnabler = @convention(c) (Int32, Bool) -> Int32
let setSymbolicHotKeyEnabled: SymbolicHotKeyEnabler? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") ?? dlsym(handle, "SLSSetSymbolicHotKeyEnabled")
    else { return nil }
    return unsafeBitCast(sym, to: SymbolicHotKeyEnabler.self)
}()

var canTurnOffNativeCommandTab: Bool { setSymbolicHotKeyEnabled != nil }

/// While the dock's own switcher has macOS's Cmd-Tab turned off, this file says so. It lets a
/// dock that crashed with Cmd-Tab off turn it back on at its next start.
let commandTabMarker: UnsafeMutablePointer<CChar> = strdup(
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/workspace-bar/cmdtab-off").path)!
nonisolated(unsafe) var turnedOffNativeCommandTab = access(commandTabMarker, F_OK) == 0

/// macOS's own Cmd-Tab (symbolic hot key 1) and Cmd-Shift-Tab (2). The dock gives it back only if
/// the dock took it: another switcher, AltTab say, turns it off for its own use, and a dock that
/// turned it on at every start and quit took ⌘-Tab from AltTab each time (4 November).
func nativeCommandTab(_ on: Bool) {
    guard let set = setSymbolicHotKeyEnabled else { return }
    if on {
        guard turnedOffNativeCommandTab else { return }
        turnedOffNativeCommandTab = false
        unlink(commandTabMarker)
    } else {
        turnedOffNativeCommandTab = true
        close(open(commandTabMarker, O_CREAT | O_WRONLY, 0o644))
    }
    for key: Int32 in [1, 2] { _ = set(key, on) }
}

/// Whatever ends the process gives macOS its switcher back first.
func restoreCommandTabOnExit() {
    for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
        signal(sig) { s in
            nativeCommandTab(true)
            signal(s, SIG_DFL)
            raise(s)
        }
    }
    for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
        signal(sig) { s in
            nativeCommandTab(true)
            signal(s, SIG_DFL)
            raise(s)
        }
    }
}

@MainActor
final class Switcher: ObservableObject {
    @Published var apps: [NSRunningApplication] = []
    @Published var index = 0
    @Published var mode = ""
    @Published var tint = Color.accentColor
    var pick: ((Int) -> Void)?
}

struct SwitcherView: View {
    @ObservedObject var s: Switcher

    var body: some View {
        let side = s.apps.count > 10 ? max(44, 72 - CGFloat(s.apps.count - 10) * 3) : 72
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(s.tint).frame(width: 7, height: 7)
                Text(s.mode).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(Array(s.apps.enumerated()), id: \.element.processIdentifier) { i, app in
                    Image(nsImage: app.icon ?? NSImage())
                        .resizable().interpolation(.high)
                        .frame(width: side, height: side)
                        .opacity(app.isHidden ? 0.55 : 1)
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(i == s.index ? 0.16 : 0)))
                        .contentShape(Rectangle())
                        .onTapGesture { s.pick?(i) }
                }
            }
            Text(s.apps.indices.contains(s.index) ? (s.apps[s.index].localizedName ?? "") : "")
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .fixedSize()
        .animation(.snappy(duration: 0.12), value: s.index)
    }
}

/// The event tap's callback: a C function, so the controller rides in `info`.
private let tapCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<SwitcherController>.fromOpaque(info).takeUnretainedValue()
    return MainActor.assumeIsolated { me.handle(type, event) }
}

@MainActor
final class SwitcherController {
    let model: DockModel
    let state = Switcher()
    var panel: NSPanel!
    var host: NSHostingView<SwitcherView>!
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var switching = false
    var showWork: DispatchWorkItem?
    var recent: [pid_t] = []   // activation order, newest first

    init(model: DockModel) {
        self.model = model
        host = NSHostingView(rootView: SwitcherView(s: state))   // sized by SwiftUI: fittingSize is its size
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = host
        state.pick = { [weak self] i in
            self?.state.index = i
            self?.commit()
        }
        if let f = NSWorkspace.shared.frontmostApplication { recent = [f.processIdentifier] }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                self.recent.removeAll { $0 == pid }
                self.recent.insert(pid, at: 0)
            }
        }
    }

    /// On when the config asks for it (the default) and the event tap can be made; otherwise
    /// macOS's switcher is put back.
    func apply(_ on: Bool) {
        // Without the call, macOS's switcher cannot be turned off, and two switchers would answer.
        if on, !canTurnOffNativeCommandTab {
            log("Cmd-Tab: this macOS has no call to turn its switcher off; macOS's switcher stays")
            return
        }
        if on, tap == nil {
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: CGEventMask(mask), callback: tapCallback,
                                    userInfo: Unmanaged.passUnretained(self).toOpaque())
            if let tap {
                source = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                log("Cmd-Tab: no event tap (Accessibility not granted?), macOS's switcher stays")
            }
        } else if !on, let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            self.tap = nil
            source = nil
            cancel()
        }
        nativeCommandTab(tap == nil)
        log("Cmd-Tab: \(tap == nil ? "left to macOS or another switcher (AltTab)" : "the current mode's apps only")")
    }

    /// The current mode's running apps and the shared ones, most recently used first. An app no
    /// mode has claimed yet is listed too: bringing it forward claims it for this mode.
    func candidates() -> [NSRunningApplication] {
        var seen = Set<String>()
        let apps = model.regularApps.filter { a in
            guard !a.isTerminated, let id = a.bundleIdentifier else { return false }
            let owner = model.owner(id)
            return model.isShared(id) || owner == model.state.current || owner == nil
        }
        let rank = { (a: NSRunningApplication) in self.recent.firstIndex(of: a.processIdentifier) ?? Int.max }
        return apps.sorted { (rank($0), $0.launchDate ?? .distantPast) < (rank($1), $1.launchDate ?? .distantPast) }
            .filter { seen.insert($0.bundleIdentifier ?? "").inserted }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("Cmd-Tab: event tap disabled (\(type.rawValue)), turning it back on")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if switching, !NSEvent.modifierFlags.contains(.command) { commit() }   // Cmd went up while it was off
            return pass
        }
        let flags = event.flags, key = event.getIntegerValueField(.keyboardEventKeycode)
        // A Cmd-up lost while the tap was off (the main thread stalled): the switch ended then,
        // so commit it and let this key through instead of swallowing every key from now on.
        if switching, type != .flagsChanged, !flags.contains(.maskCommand) { commit(); return pass }
        let cmdTab = key == 48 && flags.contains(.maskCommand) && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
        switch type {
        case .flagsChanged:
            if switching && !flags.contains(.maskCommand) { commit() }
            return pass
        case .keyDown:
            if cmdTab {
                step(flags.contains(.maskShift) ? -1 : 1)
                return nil
            }
            guard switching else { return pass }
            switch key {
            case 53: cancel()                    // Escape
            case 123: step(-1)                   // left arrow
            case 124: step(1)                    // right arrow
            case 36: commit()                    // Return
            case 12: quitSelected()              // Q quits the selected app, as in macOS
            case 4: hideSelected()               // H hides it
            default: break
            }
            return nil
        case .keyUp:
            return switching || cmdTab ? nil : pass
        default:
            return pass
        }
    }

    func step(_ d: Int) {
        if !switching {
            let list = candidates()
            guard !list.isEmpty else { return }
            state.apps = list
            state.mode = model.state.current
            state.tint = Color(hex: model.currentMode?.color ?? "#888888")
            state.index = list.count == 1 ? 0 : (d > 0 ? 1 : list.count - 1)
            switching = true
            // A quick Cmd-Tab switches without the panel flashing up, as macOS's does.
            let work = DispatchWorkItem { [weak self] in self?.show() }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        } else if !state.apps.isEmpty {
            state.index = (state.index + d + state.apps.count) % state.apps.count
        }
    }

    /// Lay the panel out once at launch. The first layout, the first material and the first icon
    /// of each app are the slow part of a show, so they are paid here instead of on the first
    /// Cmd-Tab. It is placed off screen so nothing flashes.
    func prewarm() {
        let list = candidates()
        guard !list.isEmpty else { return }
        state.apps = list
        state.mode = model.state.current
        state.tint = Color(hex: model.currentMode?.color ?? "#888888")
        state.index = 0
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width >= 1, size.height >= 1 else { state.apps = []; return }
        panel.setFrame(NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), display: false)
        panel.orderFrontRegardless()
        panel.orderOut(nil)
        state.apps = []
    }

    func show() {
        guard switching, let screen = NSScreen.screens.first else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width >= 1, size.height >= 1 else { log("Cmd-Tab: panel has no size yet"); return }
        let f = screen.frame
        panel.setFrame(NSRect(x: (f.midX - size.width / 2).rounded(), y: (f.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func commit() {
        guard switching else { return }
        let pick = state.apps.indices.contains(state.index) ? state.apps[state.index] : nil
        log("Cmd-Tab: switch to \(pick?.bundleIdentifier ?? "-")\(panel.isVisible ? " (panel shown)" : "")")
        cancel()
        if let pick, pick.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let at = Date()
            let pid = pick.processIdentifier, id = pick.bundleIdentifier ?? "?"
            model.expect(id)
            Vis.focus(pick)
            pollFront(pid: pid, id: id, since: at, tries: 60)
        }
    }

    /// Logs how long the app took to come forward. The switch is what felt slow, so the line
    /// measures it: one message a switch, and the number names the side that lost the time.
    private func pollFront(pid: pid_t, id: String, since: Date, tries: Int) {
        guard tries > 0 else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            log("Cmd-Tab: \(id) front in \(Int(Date().timeIntervalSince(since) * 1000))ms")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.pollFront(pid: pid, id: id, since: since, tries: tries - 1)
        }
    }

    func cancel() {
        switching = false
        showWork?.cancel()
        panel.orderOut(nil)
    }

    func hideSelected() {
        guard state.apps.indices.contains(state.index) else { return }
        Vis.set([state.apps[state.index]], visible: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.state.objectWillChange.send() }
    }

    /// Quit the selected app and keep switching among the rest.
    func quitSelected() {
        guard state.apps.indices.contains(state.index) else { return }
        _ = state.apps[state.index].terminate()
        state.apps.remove(at: state.index)
        if state.apps.isEmpty { cancel(); return }
        state.index = min(state.index, state.apps.count - 1)
        if panel.isVisible { show() }
    }
}
