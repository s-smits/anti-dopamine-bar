// Anti-Dopamine Dock: a dock at the bottom of the screen with three modes. Each app belongs to one mode.
// Leaving a mode hides its apps; entering one brings back, all at once, its front app and the apps
// that had a window in one of Rectangle's fields (a half, third, quarter or maximised), and leaves
// the rest hidden until you ask for them (Cmd-Tab, or the mode's card on hover).
// Cmd-Tab lists only the current mode's apps and the shared ones (switcher.swift), an add-in.
// Hidden windows keep their frames, so a layout made with Rectangle survives the switch, and the
// dock's app icons offer Rectangle's layouts on right-click (through its rectangle:// URL scheme).
// It stands just above the screen's lower edge; drag it sideways, double-click to centre it, and
// drag its right end to resize it. Windows of the front app are kept above it, and it steps aside
// while the front app fills the screen (a full-screen space, a video, a game).
// A mode with a "gate" makes you wait before it opens: during a focus round the first three clicks
// only light a halo around the pomodoro, the next starts the wait, and each further click cuts it.
// The wait runs on through mode switches and restarts. When it runs out it opens the mode only if
// you clicked in the last 10 s; otherwise the mode waits, outlined, for your next click. The pomodoro
// on the right runs the day's plan, shown when you hover it: during a break a gated mode opens at
// once, and when the break ends the dock takes you back to the mode you came from.
//
// Config: ~/.config/workspace-bar/config.json. Remembered apps: ~/.config/workspace-bar/state.json.

import AppKit
import Combine
import SwiftUI

// Every app belongs to one mode. An app the config names under a mode's "apps" always belongs
// there; any other app belongs to the mode it was first seen in, until moved from its icon's menu.
// An app of another mode that shows up (Cmd-Tab, the macOS Dock, a notification) is hidden again.

// MARK: - Config and state

/// A mode that waits: during a focus round it opens at the break, at once with the timer paused,
/// or sooner by clicking. (A config's old `cutPerClick` and `floorSeconds` are read past: a third a
/// click let it open after seconds of fast clicking.)
struct Gate: Codable {
    var startMinutes: Double   // the wait when no focus round is running (its rules: GateCore)
}

struct Mode: Codable {
    var name: String
    var icon: String           // SF Symbol name
    var color: String          // hex, e.g. #2F6BD8
    var gate: Gate?
    var apps: [String]?        // bundle ids that always belong to this mode
}

struct Pomodoro: Codable {
    var focusMinutes: Double
    var breakMinutes: Double

    /// The day: sixteen rounds in four sets of four, each round with a break after it. A set's breaks
    /// are short but its last, which is lunch after the second set and 15 minutes after the others.
    var plan: [PomoBlock] {
        let endings = [PomoBlock(kind: .rest, minutes: 15), PomoBlock(kind: .lunch, minutes: 45),
                       PomoBlock(kind: .rest, minutes: 15), PomoBlock(kind: .rest, minutes: 15)]
        return endings.flatMap { end -> [PomoBlock] in
            (1...4).flatMap { round -> [PomoBlock] in
                [PomoBlock(kind: .focus, minutes: focusMinutes),
                 round < 4 ? PomoBlock(kind: .rest, minutes: breakMinutes) : end]
            }
        }
    }
}

struct PomoBlock {
    enum Kind { case focus, rest, lunch }
    let kind: Kind
    let minutes: Double
}

struct Config: Codable {
    var modes: [Mode]
    var pomodoro: Pomodoro?
    var alwaysVisible: [String]   // bundle ids shared by every mode: never hidden, shown in each dock
    var sharedPrefixes: [String]? // bundle id prefixes shared by every mode, unless an app is pinned to one
    var socialSites: [String]?    // sites the browser extension blocks outside a gated mode; nil: ModeServer's list
    var addIns: AddIns?           // other apps the dock works with; each one left out is on
}

/// What the dock does to other apps, each switched on and off from the dock's menu (Add-ins).
/// One left out of the config is on, as it was before they could be switched off. The menu lists
/// only those whose app is installed (`apps`, any one of them; none needed when empty), and one
/// whose app is missing does nothing until the app turns up (DockModel.active).
struct AddIns: Codable, Equatable {
    var switcher: Bool?     // the dock's AltTab-style Cmd-Tab lists the current mode's apps (SwitcherController);
                            // off: macOS's switcher, or AltTab's. Until 7 November a toggle of its own in the menu
    var raycast: Bool?      // Raycast hides the gated mode's apps outside that mode (RaycastSync)
    var rectangle: Bool?    // Rectangle's bottom gap follows the dock; its layouts on an app's right-click
    var brave: Bool?        // the dock tells the browser extension in Brave the mode (ModeServer)
    var chrome: Bool?       // the same extension in Chrome, and in any other Chromium browser
    var firefox: Bool?      // the Firefox build of the extension
    var optionKeys: Bool?   // Option-1 to 3 click the first three modes (ModeHotKeys)
    var hooks: Bool?        // your own scripts in ~/.config/workspace-bar/hooks run on each switch (Hooks)

    struct Item {
        let title: String
        let key: WritableKeyPath<AddIns, Bool?>
        let apps: [String]
    }

    static let all: [Item] = [
        Item(title: "AltTab-Style Cmd-Tab: This Mode's Apps Only", key: \.switcher, apps: []),
        Item(title: "Raycast: Hide Socials Apps Outside Socials", key: \.raycast, apps: ["com.raycast.macos"]),
        Item(title: "Rectangle: Leave Room for the Dock", key: \.rectangle, apps: ["com.knollsoft.Rectangle"]),
        Item(title: "Brave Extension: Block Social Sites", key: \.brave,
             apps: ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"]),
        Item(title: "Chrome Extension: Block Social Sites", key: \.chrome,
             apps: ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"]),
        Item(title: "Firefox Add-on: Block Social Sites", key: \.firefox,
             apps: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]),
        Item(title: "Option-1 to 3 Switch Modes", key: \.optionKeys, apps: []),
        Item(title: "Custom Hooks on Mode Switch", key: \.hooks, apps: []),
    ]

    /// The browser add-ins, by the name the extension gives the mode server (`?browser=`).
    static let browsers: [(name: String, key: WritableKeyPath<AddIns, Bool?>)] = [
        ("brave", \.brave), ("chrome", \.chrome), ("firefox", \.firefox),
    ]
}

struct SavedState: Codable, Equatable {
    var current: String
    var apps: [String: [String]] = [:]    // mode -> bundle ids open when it was left
    var focus: [String: String] = [:]     // mode -> bundle id that had focus
    var dockLeft: Double?                 // dock's left edge once dragged
    var scale: Double?                    // dock size, 1 is normal
    var pomoPhase: String?                // "focus" or "break"; nil when idle
    var pomoEnd: Date?                    // set while running
    var pomoLeft: Double?                 // set while paused
    var pomoCount: Int?                   // focus rounds finished today
    var pomoDay: String?
    var pomoBlock: Int?                   // the plan's block running or, when idle, the next to run
    var returnTo: String?                // mode to go back to when a break ends
    var shown: [String: [String]]?        // mode -> apps to bring back: in front or in a Rectangle field
    var gatePending: String?              // a gated mode being waited for, kept across restarts
    var gateDeadline: Date?
    var gateTotal: Double?
    var gateReady: String?                // a gated mode whose wait ran out: the next click opens it
    var order: [String: [String]]?        // mode -> its apps in the order you put them; the card shows the first five
    var usage: [String: Use]?             // app -> how much it is used, fading by half every three days
    var sharedUsage: [String: [String: Use]]?  // mode -> shared app -> how much it is used in that mode
    var rectangleOwn: RectangleOwn?       // Rectangle's settings before the dock first set its gap
}

/// What Rectangle had before the Rectangle add-in changed it, given back when the add-in is switched off.
struct RectangleOwn: Codable, Equatable {
    var gap: Double?        // screenEdgeGapBottom; nil: unset
    var mainOnly: Bool?     // screenEdgeGapsOnMainScreenOnly; nil: unset
}

struct Use: Codable, Equatable {
    var score: Double
    var at: Date
}

/// An icon being dragged along a mode's card: the card's apps in their order so far, the icon,
/// the place it started from and how far the mouse has gone.
struct CardDrag {
    static let stride: CGFloat = 40   // an icon (36) and the gap after it
    var ids: [String]
    var id: String
    var from: Int
    var dx: CGFloat
}

let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/workspace-bar")
let configURL = dir.appendingPathComponent("config.json")
let stateURL = dir.appendingPathComponent("state.json")

/// Shown in every mode's dock, whatever the config says. On 4 November the menu's "Move to" took it
/// off the shared list for good, so the other two modes lost it and clicking it left them.
let finderID = "com.apple.finder"

/// Browsers are shared by every mode unless pinned to one: a browser serves each mode, its windows
/// stay up through a switch, and the browser add-in's extension keeps social sites to Socials.
/// Owned by one mode, a browser hid in the others and clicking it took you back (8 November).
let browserIDs: Set<String> = [
    "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
    "org.chromium.Chromium", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
    "com.apple.Safari", "com.apple.SafariTechnologyPreview", "company.thebrowser.Browser", "company.thebrowser.dia",
    "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "app.zen-browser.zen", "com.kagi.kagimacOS",
]

/// Shared by every mode unless pinned to one: a browser, or an app matching a shared prefix (Brave's web apps).
func sharedByDefault(_ id: String, _ config: Config) -> Bool {
    browserIDs.contains(id) || (config.sharedPrefixes ?? []).contains { id.hasPrefix($0) }
}

let defaultConfig = Config(modes: [
    Mode(name: "Profile 1", icon: "1.circle.fill", color: "#2F6BD8", gate: nil, apps: nil),
    Mode(name: "Profile 2", icon: "2.circle.fill", color: "#D7891E", gate: nil, apps: nil),
    Mode(name: "Socials", icon: "bubble.left.and.bubble.right.fill", color: "#D9443F",
         gate: Gate(startMinutes: 25),
         apps: ["net.whatsapp.WhatsApp", "com.hnc.Discord", "com.tinyspeck.slackmacgap"]),
], pomodoro: Pomodoro(focusMinutes: 25, breakMinutes: 5), alwaysVisible: [finderID],
   sharedPrefixes: ["com.brave.Browser.app."])   // Brave's web apps: each has its own bundle id

func readJSON<T: Decodable>(_ url: URL, _ type: T.Type) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    do { return try JSONDecoder().decode(type, from: data) } catch {
        log("cannot read \(url.lastPathComponent): \(error)")
        return nil
    }
}

/// The dock's slow work runs off the main thread, so a busy machine slows that work and not the
/// dock's drawing or clicks. Accessibility calls wait on the other app, up to a second each, and
/// file writes on the disk. Each queue is serial, so its calls keep the order they were made in.
let axQueue = DispatchQueue(label: "workspacebar.ax", qos: .userInteractive)
/// Every show, hide and focus of an app runs on that app's own serial queue, in this group: calls to
/// one app keep their order, and a slow app no longer holds up the others. A switch that hid five
/// apps one after another took as long as all five answers together; now it takes the slowest one.
let axGroup = DispatchGroup()

/// The number of the latest focus, read from the Accessibility queues as well as the main thread.
final class FocusTicket: @unchecked Sendable {
    static let shared = FocusTicket()
    private let lock = NSLock()
    private var value = 0
    var current: Int {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// A list filled from several queues.
final class Bag<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) { lock.lock(); items.append(x); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}
let ioQueue = DispatchQueue(label: "workspacebar.io", qos: .utility)

func writeJSON<T: Encodable>(_ url: URL, _ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? enc.encode(value) else { return }
    ioQueue.async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

func loadConfig() -> Config {
    if !FileManager.default.fileExists(atPath: configURL.path) { writeJSON(configURL, defaultConfig); return defaultConfig }
    var config = readJSON(configURL, Config.self) ?? defaultConfig
    if !config.alwaysVisible.contains(finderID) { config.alwaysVisible.insert(finderID, at: 0) }
    return config
}

/// A repeating main-thread timer with 10% slack, so that macOS can wake the dock together with
/// other work instead of on its own.
/// `@Published` that stays quiet when a write leaves the value as it was. The dock writes its
/// state on most events, often unchanged, and each change notice redraws the whole dock.
@propertyWrapper struct Changed<Value: Equatable> {
    private var value: Value
    private let subject: CurrentValueSubject<Value, Never>
    init(wrappedValue: Value) { value = wrappedValue; subject = CurrentValueSubject(wrappedValue) }
    var projectedValue: AnyPublisher<Value, Never> { subject.eraseToAnyPublisher() }
    @available(*, unavailable, message: "only in an ObservableObject")
    var wrappedValue: Value { get { fatalError() } set { fatalError() } }

    static subscript<T: ObservableObject>(_enclosingInstance o: T, wrapped _: ReferenceWritableKeyPath<T, Value>,
                                          storage s: ReferenceWritableKeyPath<T, Self>) -> Value
        where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        get { o[keyPath: s].value }
        set {
            guard o[keyPath: s].value != newValue else { return }
            o.objectWillChange.send()
            o[keyPath: s].value = newValue
            o[keyPath: s].subject.send(newValue)
        }
    }
}

@MainActor @discardableResult
func every(_ seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
    let t = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in MainActor.assumeIsolated { body() } }
    t.tolerance = seconds / 10
    return t
}

/// Seconds since the last key press, click or mouse move anywhere. With nobody at the Mac, windows
/// hold still, so the checks that watch them can run less often.
var idleSeconds: TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

func log(_ s: String) {
    FileHandle.standardError.write("\(stamp.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

extension Color {
    init(hex: String) {
        let v = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Apps and Rectangle

@MainActor
enum Apps {
    /// Open the app through LaunchServices, as the macOS Dock does: launch it, or activate the
    /// running one and send it a reopen, which unhides it, brings back a minimised window and makes
    /// a browser with no window open one. LaunchServices may activate an app from the background,
    /// where a plain activate() from the dock is often refused. Where only headless instances run, a
    /// new one starts, since LaunchServices would hand the open to a process that never shows a window.
    static func open(_ id: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            log("open \(id): no such app installed")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = running(id).isEmpty
            && !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            if let error { log("open \(id): \(error.localizedDescription)") }
        }
    }

    /// Bring an app up from a click (the card, a dock icon, a gated mode opening): the one way the
    /// dock opens apps. LaunchServices does it, as above, unless headless instances run beside a real
    /// one: then LaunchServices might pick a headless one, so the real one is activated by its pid.
    /// A watch then makes sure it came: see `watch`.
    static func bringUp(_ id: String, _ instance: NSRunningApplication? = nil) {
        opening += 1
        let real = running(id), all = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        if let app = ([instance].compactMap { $0 } + real).first(where: WindowServer.hasWindowHere) {
            Vis.focus(app)   // a window to show: straight to the WindowServer, the fastest way
        } else if real.isEmpty || real.count == all.count {
            open(id)         // not running, no window, or only minimised ones: the Dock's reopen
        } else {
            Vis.focus(instance ?? windowed(id).first ?? real[0])
        }
        watch(id, ticket: opening, since: Date(), before: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    static var opening = 0   // bumped by each bringUp, so only the latest one is watched

    /// Logs when the app came forward. If after a second it has not and nothing else took the
    /// front meanwhile (LaunchServices dropped the activation, say), it is activated directly, once.
    /// A launch may take longer: the watch gives up after eight seconds.
    static func watch(_ id: String, ticket: Int, since: Date, before: pid_t?, nudged: Bool = false) {
        guard ticket == opening else { return }
        let t = Date().timeIntervalSince(since)
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == id, let pid = front?.processIdentifier, !WindowServer.covered(pid) || t > 1.5 {
            log("open \(id): in front after \(Int(t * 1000)) ms\(nudged ? ", activated directly" : "")")
            return
        }
        if t > 8 { log("open \(id): not in front after 8 s (front: \(front?.bundleIdentifier ?? "-"))"); return }
        var nudged = nudged
        if !nudged, t > 1, front?.processIdentifier == before || front?.bundleIdentifier == id, let app = windowed(id).first ?? running(id).first {
            nudged = true
            Vis.focus(app)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            watch(id, ticket: ticket, since: since, before: before, nudged: nudged)
        }
    }

    /// Instances with a window, on any Space and hidden ones included.
    static func windowed(_ id: String) -> [NSRunningApplication] {
        let apps = running(id)
        guard !apps.isEmpty else { return [] }
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let owners = Set(list.compactMap { w in
            (w[kCGWindowLayer as String] as? Int) == 0 ? w[kCGWindowOwnerPID as String] as? pid_t : nil
        })
        return apps.filter { owners.contains($0.processIdentifier) }
    }

    /// Whether a process was started with `--headless`. An automation tool's browser runs under the
    /// browser's own bundle id but never shows a window: on 4 November two orphaned Playwright Chromes
    /// took every open of Chrome, from the card and from Raycast alike, and nothing appeared.
    static var headlessCache: [pid_t: Bool] = [:]
    static func headless(_ pid: pid_t) -> Bool {
        if let known = headlessCache[pid] { return known }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return false }
        let args = String(decoding: buf.prefix(size).map { $0 == 0 ? 32 : $0 }, as: UTF8.self)
        let found = args.contains(" --headless")
        if headlessCache.count > 500 { headlessCache.removeAll() }
        headlessCache[pid] = found
        return found
    }

    /// Bring the app to the front, then ask Rectangle to place its front window.
    static func place(_ id: String, _ action: String) {
        Vis.focus(id)
        Task { @MainActor in
            for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != id {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard let url = URL(string: "rectangle://execute-action?name=\(action)") else { return }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false   // like `open -g`: Rectangle must not take the front
            _ = try? await NSWorkspace.shared.open(url, configuration: cfg)
        }
    }

    /// Running instances, headless ones left out.
    static func running(_ id: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !headless($0.processIdentifier) }
    }

    static let layouts: [(String, String)] = [
        ("Left Half", "left-half"), ("Right Half", "right-half"), ("Maximize", "maximize"),
        ("Almost Maximize", "almost-maximize"), ("Center", "center"),
        ("First Third", "first-third"), ("Center Third", "center-third"), ("Last Third", "last-third"),
        ("First Two Thirds", "first-two-thirds"), ("Last Two Thirds", "last-two-thirds"),
        ("Top Left", "top-left"), ("Top Right", "top-right"),
        ("Bottom Left", "bottom-left"), ("Bottom Right", "bottom-right"),
    ]
}

// MARK: - Showing, hiding and focusing apps

/// Fronting another app's window the way AltTab does (lwouis/alt-tab-macos, GPL-3.0:
/// src/macos/api-wrappers/SkyLight.framework.swift and Window.applyFocus, ported from yabai and
/// Hammerspoon issue 370). Since macOS 14 `NSRunningApplication.activate` is only a request, which
/// macOS often turns down for a background app like the dock; the WindowServer's own calls are not.
///   1. `_SLPSSetFrontProcessWithOptions(psn, wid, userGenerated)` makes the app front with that
///      window on top, and only that window.
///   2. `makeKeyWindow` posts a bare mouse-down aimed at the window by id, far past its bottom-right
///      corner, so the window becomes key without anything in it being clicked (AltTab: a point near
///      the window resized it on macOS 27; a down/up pair can press a button).
/// The calls are private, so they are looked up when the dock starts, not linked: a macOS without
/// them still runs the dock, and focusing falls back to the public calls.
enum WindowServer {
    typealias FrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    typealias PsnFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias WidFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let image = dlopen(nil, RTLD_NOW)
    static func find<T>(_ name: String, _: T.Type) -> T? {
        guard let image, let p = dlsym(image, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    nonisolated(unsafe) static let setFront = find("_SLPSSetFrontProcessWithOptions", FrontFn.self)
    nonisolated(unsafe) static let postEvent = find("SLPSPostEventRecordTo", PostFn.self)
    nonisolated(unsafe) static let psnFor = find("GetProcessForPID", PsnFn.self)
    nonisolated(unsafe) static let widOf = find("_AXUIElementGetWindow", WidFn.self)

    /// Step 3, on the app's queue: raise that very window within the app, through Accessibility.
    /// AltTab found steps 1 and 2 could both succeed and leave another window on top (its #6064), and
    /// an app with several windows can keep another of its own in front; a raise settles both. Done
    /// only while this focus is still the latest, since raising a window of an app you have since
    /// left would put it back over the one you went to.
    nonisolated static func raise(_ pid: pid_t, _ wid: CGWindowID, ticket: Int) {
        guard let widOf, FocusTicket.shared.current == ticket else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for w in windows {
            var id: CGWindowID = 0
            guard widOf(w, &id) == .success, id == wid else { continue }
            guard FocusTicket.shared.current == ticket else { return }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            return
        }
    }

    static var available: Bool { setFront != nil && postEvent != nil && psnFor != nil }

    static let userGenerated: UInt32 = 0x200   // the switch counts as the user's (yabai's kCPSUserGenerated)

    /// Steps 1 and 2. False where the calls are missing or the WindowServer said no.
    static func front(_ pid: pid_t, _ wid: CGWindowID) -> Bool {
        guard let setFront, let postEvent, let psnFor else { return false }
        var psn = ProcessSerialNumber()
        guard psnFor(pid, &psn) == noErr else { return false }
        guard setFront(&psn, wid, userGenerated) == .success else { return false }
        // The event record, as AltTab lays it out: 0xf8 bytes, in a zeroed 0x100 buffer because the
        // WindowServer reads past the record on macOS 14.7.4 and later.
        var bytes = [UInt8](repeating: 0, count: 0x100)
        var wid = wid
        var point = CGPoint(x: 300_000, y: 300_000)
        bytes[0x04] = 0xf8                         // the record's length
        bytes[0x3a] = 0x10                         // undocumented; yabai and Hammerspoon set it
        memcpy(&bytes[0x3c], &wid, MemoryLayout<CGWindowID>.size)      // delivered to this window
        memcpy(&bytes[0x20], &point, MemoryLayout<CGPoint>.size)       // far off any content
        bytes[0x08] = 0x01                         // kCGEventLeftMouseDown, without the up
        _ = postEvent(&psn, &bytes)
        return true
    }

    /// The app's top window: on screen on this Space if it has one (the window list runs front to
    /// back), else any of its normal windows (a hidden app's, or one on another Space).
    static func topWindow(_ pid: pid_t) -> CGWindowID? {
        func first(_ options: CGWindowListOption) -> CGWindowID? {
            let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
            return list.first { w in
                guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                      let b = w[kCGWindowBounds as String] as? [String: Double] else { return false }
                return (b["Width"] ?? 0) > 60 && (b["Height"] ?? 0) > 60
            }.flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
        }
        return first([.optionOnScreenOnly, .excludeDesktopElements]) ?? first([.optionAll, .excludeDesktopElements])
    }

    /// Whether another app's window lies over the app's top window on screen, over at least a
    /// quarter of it: in front by name, as the menu bar and the dock's dot say, yet still behind on
    /// screen. Seen on 4 November (19:49): Brave frontmost, Ghostty's window still over Brave's. A
    /// window on another display, or a small one off to the side, does not count.
    static func covered(_ pid: pid_t) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var above: [CGRect] = []
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner != me,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: d), r.width > 60, r.height > 60 else { continue }
            if owner != pid { above.append(r); continue }
            let area = r.width * r.height
            return above.contains { o in
                let i = o.intersection(r)
                return !i.isNull && i.width * i.height >= area / 4
            }
        }
        return false
    }

    /// Whether the app has a window you would see on this Space once it is unhidden: one on screen
    /// now, or any at all while the app is hidden. Not one only minimised or on another Space.
    static func hasWindowHere(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        let options: CGWindowListOption = app.isHidden ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double] else { return false }
            return (b["Width"] ?? 0) > 60 && (b["Height"] ?? 0) > 60
        }
    }
}

/// Small readers and writers over the Accessibility API. Every call waits at most a second, so an
/// app that has stopped responding cannot freeze the dock for long. A quarter of a second was too
/// short: WhatsApp, busy coming to the front, answered a hide later than that (3 November 2026).
enum AX {
    static let ready: Void = { _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0) }()
    static func get(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    static func windows(_ pid: pid_t) -> [AXUIElement] {
        get(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }
    static func string(_ e: AXUIElement, _ a: String) -> String? { get(e, a) as? String }
    /// Whether the app's focused window (or else its main one) is in macOS full screen.
    static func fullScreen(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let w = get(app, kAXFocusedWindowAttribute) ?? get(app, kAXMainWindowAttribute),
              CFGetTypeID(w) == AXUIElementGetTypeID() else { return false }
        return bool(w as! AXUIElement, "AXFullScreen") == true
    }
    static func bool(_ e: AXUIElement, _ a: String) -> Bool? { (get(e, a) as? NSNumber)?.boolValue }
    static func point(_ e: AXUIElement) -> CGPoint? {
        guard let v = get(e, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
    static func size(_ e: AXUIElement) -> CGSize? {
        guard let v = get(e, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
    static func setPoint(_ e: AXUIElement, _ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v) == .success
    }
    static func setSize(_ e: AXUIElement, _ s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, v) == .success
    }
}

/// Whether an app has a window in one of Rectangle's fields: every edge on Rectangle's grid of
/// halves, thirds and quarters of the screen, inside its edge gaps. Rectangle keeps no record of
/// what it placed, and its keyboard shortcuts bypass the dock, so the window's frame is the evidence.
enum Tiles {
    static func pref(_ key: String) -> CGFloat {
        CGFloat((CFPreferencesCopyAppValue(key as CFString, "com.knollsoft.Rectangle" as CFString) as? NSNumber)?.doubleValue ?? 0)
    }

    /// Rectangle's working area on one screen in Accessibility coordinates, y down from the top of
    /// the main screen, and how far off its grid an edge may be.
    struct Area { var l, r, t, b, tolerance: CGFloat }

    /// One area for each screen. Read on the main thread, where NSScreen lives. Rectangle's edge
    /// gaps apply to the main screen alone when `screenEdgeGapsOnMainScreenOnly` is set, as the
    /// Rectangle add-in sets it (Rectangle's ScreenDetection.swift: `self != NSScreen.screens.first`).
    @MainActor static func areas() -> [Area] {
        guard Vis.trusted, let main = NSScreen.screens.first else { return [] }
        let top = main.frame.maxY, mainOnly = pref("screenEdgeGapsOnMainScreenOnly") != 0
        return NSScreen.screens.map { s in
            let vf = s.visibleFrame, g = s == main || !mainOnly ? 1 : 0 as CGFloat
            return Area(l: vf.minX + g * pref("screenEdgeGapLeft"), r: vf.maxX - g * pref("screenEdgeGapRight"),
                        t: top - vf.maxY + g * pref("screenEdgeGapTop"), b: top - vf.minY - g * pref("screenEdgeGapBottom"),
                        tolerance: pref("gapSize") + 8)
        }
    }

    static func placed(_ pid: pid_t, _ areas: [Area]) -> Bool {
        let xs: [CGFloat] = [0, 1 / 4, 1 / 3, 1 / 2, 2 / 3, 3 / 4, 1], ys: [CGFloat] = [0, 1 / 2, 1]
        return AX.windows(pid).contains { w in
            guard AX.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole, AX.bool(w, kAXMinimizedAttribute) != true,
                  let p = AX.point(w), let sz = AX.size(w) else { return false }
            return areas.contains { a in
                func onGrid(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat, _ fs: [CGFloat]) -> Bool {
                    fs.contains { abs(v - (lo + (hi - lo) * $0)) <= a.tolerance }
                }
                return sz.width > (a.r - a.l) / 5
                    && onGrid(p.x, a.l, a.r, xs) && onGrid(p.x + sz.width, a.l, a.r, xs)
                    && onGrid(p.y, a.t, a.b, ys) && onGrid(p.y + sz.height, a.t, a.b, ys)
            }
        }
    }
}

/// NSRunningApplication.hide() and unhide() answer false from an app that is not active, yet they
/// work (`set` below). Accessibility is the second try, and System Events, which took 1 to 3 s a
/// call and let other app events run in the middle (a stale hide once hid Ghostty in its own mode),
/// is the last resort.
@MainActor
enum Vis {
    static var trusted: Bool { AX.ready; return AXIsProcessTrusted() }

    static func askForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    nonisolated static func ax(_ pid: pid_t, _ id: String, _ attribute: String, _ value: Bool) -> Bool {
        let err = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), attribute as CFString,
                                               value ? kCFBooleanTrue : kCFBooleanFalse)
        if err != .success { log("  Accessibility \(attribute) on \(id): error \(err.rawValue)") }
        return err == .success
    }

    /// Show or hide apps. NSRunningApplication.hide() and unhide() are one message each and do not
    /// wait for the app: under a millisecond to make, the window gone 6 to 21 ms later (measured on
    /// this Mac, 4 November, as AltTab's Application.hideOrShow does it). Their answer means nothing:
    /// they say false when it worked, which the dock once took for a refusal and sent every switch
    /// to System Events. Accessibility waits on each app instead, up to a second for a busy one, so
    /// it is only the second try, half a second on, for whatever has not changed by then, and the
    /// first for apps without a Dock icon, which the messages do not reach.
    static var want: [pid_t: Bool] = [:]   // the latest visibility asked of each app

    static func set(_ apps: [NSRunningApplication], visible: Bool) {
        guard !apps.isEmpty else { return }
        for app in apps {
            want[app.processIdentifier] = visible
            if app.activationPolicy == .regular { _ = visible ? app.unhide() : app.hide() } else { axSet(app, visible) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let left = apps.filter { !$0.isTerminated && want[$0.processIdentifier] == visible && $0.isHidden == visible }
            guard !left.isEmpty else { return }
            log("  \(visible ? "show" : "hide") \(left.compactMap(\.bundleIdentifier)) not done after 0.5 s: through Accessibility")
            for app in left { axSet(app, visible) }
        }
    }

    /// The Accessibility way, on the app's own queue, and System Events where that is refused.
    static func axSet(_ app: NSRunningApplication, _ visible: Bool) {
        guard trusted else { fallback([app], visible: visible); return }
        let pid = app.processIdentifier, id = app.bundleIdentifier ?? "?"
        onApp(pid) {
            guard !ax(pid, id, kAXHiddenAttribute, !visible) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { fallback([app], visible: visible) } }
        }
    }

    static var queues: [pid_t: DispatchQueue] = [:]

    /// Run Accessibility work for one app, after whatever was queued for it before.
    static func onApp(_ pid: pid_t, _ work: @escaping @Sendable () -> Void) {
        let q: DispatchQueue
        if let known = queues[pid] { q = known } else {
            if queues.count > 64 { queues = queues.filter { NSRunningApplication(processIdentifier: $0.key) != nil } }
            q = DispatchQueue(label: "workspacebar.ax.\(pid)", qos: .userInteractive)
            queues[pid] = q
        }
        q.async(group: axGroup, execute: work)
    }

    /// Whether every queued call has been made.
    nonisolated static var idle: Bool { axGroup.wait(timeout: .now()) == .success }

    /// The last resort: System Events, which takes one to three seconds. Only for apps still wrong.
    static func fallback(_ apps: [NSRunningApplication], visible: Bool) {
        let refused = apps.filter { !$0.isTerminated && $0.isHidden == visible && (want[$0.processIdentifier] ?? visible) == visible }
        guard !refused.isEmpty else { return }
        let pids = refused.map { String($0.processIdentifier) }.joined(separator: ", ")
        let ok = systemEvents("""
            repeat with p in {\(pids)}
                try
                    set visible of (first application process whose unix id is p) to \(visible)
                end try
            end repeat
            """)
        log("  System Events \(visible ? "show" : "hide") \(refused.compactMap(\.bundleIdentifier)) -> \(ok)")
    }

    /// Bring an app forward. The native call is one message to the window server; Accessibility
    /// waits on the other app, up to a second, and System Events waits on AppleScript. So the
    /// native call goes first and the slower paths only answer when it did not take. On 4 November
    /// a Cmd-Tab switch spent about a second in AXFrontmost, which failed, before the app came
    /// forward through AppleScript.
    static func focus(_ app: NSRunningApplication) {
        let pid = app.processIdentifier, id = app.bundleIdentifier ?? "?"
        focusTicket += 1
        let ticket = focusTicket, before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard WindowServer.available else { request(app); return }
        // Unhide, then front its top window: three messages, none waiting on the app. Then raise
        // that window on the app's own queue.
        if app.isHidden || want[pid] == false { set([app], visible: true) }
        if let wid = WindowServer.topWindow(pid), WindowServer.front(pid, wid) {
            if trusted { onApp(pid) { WindowServer.raise(pid, wid, ticket: ticket) } }
        } else {
            request(app)   // no window: ask
        }
        // In front yet covered: raise once more, as AltTab does after its #6064, and should that not
        // do either, let macOS activate it. Checked whether or not it was in front already, since a
        // click on the app in front whose window lies under another's must still bring it up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard ticket == focusTicket, !app.isTerminated, WindowServer.covered(pid) else { return }
            log("  focus \(id): in front but covered, raising again")
            onApp(pid) {
                if let wid = WindowServer.topWindow(pid), FocusTicket.shared.current == ticket, WindowServer.front(pid, wid) {
                    WindowServer.raise(pid, wid, ticket: ticket)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard ticket == focusTicket, !app.isTerminated, WindowServer.covered(pid) else { return }
                log("  focus \(id): still covered, asking macOS")
                activate(app)
            }
        }
        // Should the WindowServer not have put it in front, the public calls get their turn: only
        // for the latest focus, and only while the front is still what it was. Clicking Brave, then
        // Ghostty, then Brave again within a third of a second had each older focus's backup pull
        // its app back over the newer one (4 November, 19:49).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard ticket == focusTicket, front != pid, front == before, !app.isTerminated else { return }
            log("  focus \(id): not in front through the WindowServer, asking macOS")
            request(app)
        }
    }

    /// Bumped by each focus: a backup step of an older one stands down.
    static var focusTicket: Int {
        get { FocusTicket.shared.current }
        set { FocusTicket.shared.current = newValue }
    }

    /// The public way: activate, then Accessibility, then System Events, each only if the last did
    /// not take.
    static func request(_ app: NSRunningApplication) {
        if app.isHidden { set([app], visible: true) }
        app.activate()
        let pid = app.processIdentifier, id = app.bundleIdentifier ?? "?"
        let ticket = focusTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard ticket == focusTicket, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
            onApp(pid) {
                if ax(pid, id, kAXHiddenAttribute, false), ax(pid, id, kAXFrontmostAttribute, true) { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { activate(app) } }
            }
        }
    }

    static func activate(_ app: NSRunningApplication) {
        if app.isHidden { fallback([app], visible: true) }
        app.activate()
        let ticket = focusTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard ticket == focusTicket, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else { return }
            _ = systemEvents("set frontmost of (first application process whose unix id is \(app.processIdentifier)) to true")
        }
    }

    /// Runs `body` on the main thread once every Accessibility call queued before it has been made.
    static func afterQueued(_ body: @escaping @MainActor () -> Void) {
        axGroup.notify(queue: .main) { MainActor.assumeIsolated { body() } }
    }

    static func focus(_ id: String) {
        if let app = Apps.windowed(id).first ?? Apps.running(id).first { focus(app) }
    }

    static func systemEvents(_ body: String) -> Bool {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\"\n\(body)\nend tell")?.executeAndReturnError(&err)
        if let err { log("System Events error: \(err)") }
        return err == nil
    }
}

// MARK: - Model

/// What changes with the clock, apart from the model, so a tick redraws the two rings that show it
/// and not the whole dock. Under load a whole redraw ten times a second was most of the dock's work.
@MainActor
final class CardState: ObservableObject {
    @Published var drag: CardDrag?
}

final class Ticks: ObservableObject {
    @Published var remaining: Double = 0     // the gate's wait
    @Published var second = 0                // the pomodoro's clock
}

let pomoCard = "pomodoro plan"   // what `hovered` holds while the card shows the plan instead of a mode

@MainActor
final class DockModel: ObservableObject {
    @Published var config = loadConfig()
    @Changed var state: SavedState
    @Published var apps: [NSRunningApplication] = []
    @Published var frontmost: String?
    @Changed var pending: String?            // mode waiting behind its gate
    @Changed var ready: String?              // its wait ran out while you were away: the next click opens it
    var clickedAt = Date.distantPast         // the last click that started or cut the wait
    let ticks = Ticks()
    var remaining: Double {
        get { ticks.remaining }
        set { ticks.remaining = newValue }
    }
    var gateTotal: Double = 1
    var deadline: Date?
    var ticker: Timer?
    var onChange: (() -> Void)?
    @Published var scale: Double = 1
    @Published var natural: CGSize = .zero   // the dock's size, as SwiftUI laid it out at the scale
    var frame: (() -> NSRect)?
    var resizing: (k: Double, width: Double, mouse: Double)?
    @Changed var hovered: String?            // mode whose apps the preview shows
    var previewSize: CGSize = .zero
    var onPreviewSize: (() -> Void)?
    var modeFrames: [String: CGRect] = [:]   // each mode button, in the dock's coordinates
    var pomoFrame: CGRect?                   // the pomodoro, whose card shows the day's plan
    func cardFrame(_ name: String) -> CGRect? { name == pomoCard ? pomoFrame : modeFrames[name] }
    var onHover: ((String?) -> Void)?
    var hoverWork: DispatchWorkItem?

    var overButton = false
    var overCard = false
    var hideWork: DispatchWorkItem?

    /// The card opens after a short rest on a mode button and stays while the mouse is on the
    /// button or the card, so you can move onto it and click an app.
    func hover(_ mode: String, _ inside: Bool) {
        hoverWork?.cancel()
        overButton = inside
        if !inside { scheduleHide(); return }
        hideWork?.cancel()
        let show = { [weak self] in
            guard let self, !self.dragging, self.cardDrag == nil else { return }
            self.hovered = mode
            self.onHover?(mode)
        }
        if hovered != nil { show(); return }   // already open: follow the mouse at once
        let work = DispatchWorkItem(block: show)
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func cardHover(_ inside: Bool) {
        overCard = inside
        if inside { hideWork?.cancel() } else { scheduleHide() }
    }

    func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.overButton, !self.overCard, self.cardDrag == nil else { return }
            self.closeCard()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func closeCard() {
        cardDrag = nil
        hoverWork?.cancel()
        hideWork?.cancel()
        overCard = false
        if hovered != nil { hovered = nil; onHover?(nil) }
    }

    /// An app clicked in a mode's card: go to that mode with the app in front.
    func openFromCard(_ mode: String, _ id: String) {
        closeCard()
        log("card: open \(id) in \(mode)")
        if mode == state.current {   // an app of this mode that stayed hidden: bring it in
            bringUp(id)
            return
        }
        state.focus[mode] = id
        if config.modes.first(where: { $0.name == mode })?.gate != nil && !unblocked {
            launchOnOpen = (mode, id)   // a gated mode still waits; the app comes in front when it opens
            tap(mode)
            return
        }
        if config.modes.first(where: { $0.name == mode })?.gate != nil { cancelGate() }   // on a break: it opens now
        switchTo(mode, bring: id)
    }

    /// Apps the dock itself is bringing up, and until when. Until then nothing hides them, however
    /// slowly they launch, and their activation is taken as yours.
    var expected: [String: Date] = [:]
    func expecting(_ id: String) -> Bool { (expected[id] ?? .distantPast) > Date() }
    func expect(_ id: String) {
        expected = expected.filter { $0.value > Date() }
        expected[id] = Date().addingTimeInterval(8)
    }

    /// Every click that opens an app comes here.
    func bringUp(_ id: String, _ instance: NSRunningApplication? = nil) {
        expect(id)
        Apps.bringUp(id, instance)
    }

    var launchOnOpen: (mode: String, id: String)?

    /// A mode's apps: first in the order you put them on its card, then the one it last had in
    /// front, the running ones and the rest. A shared app is one of them where it is on the card's
    /// saved order or has been used there enough: three uses, as an app needs to overtake another.
    func ordered(_ mode: String) -> [String] {
        // Every dock icon's menu asks on each redraw: kept until the model or the running apps change.
        if let known = orderCache[mode] { return known }
        let saved = state.order?[mode] ?? []
        let earned = (state.sharedUsage?[mode]?.keys.sorted() ?? []).filter { isShared($0) && score($0, mode) >= 3 }
        let ids = (state.apps[mode] ?? []) + (config.modes.first { $0.name == mode }?.apps ?? [])
            + saved.filter(isShared) + earned
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        let running = Set(regularApps.lazy.filter { !Apps.headless($0.processIdentifier) }.compactMap(\.bundleIdentifier))
        let key = { (id: String) in
            (saved.firstIndex(of: id) ?? saved.count, -self.score(id, mode), id == self.state.focus[mode] ? 0 : 1,
             running.contains(id) ? 0 : 1)
        }
        let keyed = unique.enumerated().map { (key: key($0.element), at: $0.offset, id: $0.element) }
        let result = keyed.sorted { $0.key != $1.key ? $0.key < $1.key : $0.at < $1.at }.map(\.id)
        orderCache[mode] = result
        return result
    }
    private var orderCache: [String: [String]] = [:]
    private var clearsOrder: AnyCancellable?

    /// The mode's top five, the apps its card shows.
    func preview(_ mode: String) -> [String] { Array(ordered(mode).prefix(5)) }

    /// Apart from the model, as `Ticks` is: a drag changes it on every mouse move, and a change to
    /// the model redraws the whole dock, which made the drag stutter.
    let card = CardState()
    var cardDrag: CardDrag? {
        get { card.drag }
        set { card.drag = newValue }
    }
    var cardDragSeen = Date.distantPast

    /// An icon on the card follows the mouse once it has moved 4 pt, and the others make way.
    func cardDragChanged(_ mode: String, _ id: String, _ t: CGSize) {
        if cardDrag == nil {
            let ids = preview(mode)
            guard hypot(t.width, t.height) >= 4, let from = ids.firstIndex(of: id) else { return }
            cardDrag = CardDrag(ids: ids, id: id, from: from, dx: 0)
        }
        guard var d = cardDrag else { return }
        cardDragSeen = Date()
        d.dx = t.width
        let to = min(max(d.from + Int((t.width / CardDrag.stride).rounded()), 0), d.ids.count - 1)
        guard let at = d.ids.firstIndex(of: id), at != to else { cardDrag = d; return }
        d.ids.move(fromOffsets: IndexSet(integer: at), toOffset: to > at ? to + 1 : to)
        withAnimation(.easeOut(duration: 0.15)) { cardDrag = d }
    }

    /// The end of a press on a card icon. Returns false for a click, which opens the app.
    func cardDragEnded(_ mode: String) -> Bool {
        guard let d = cardDrag else { return false }
        saveOrder(mode, d.ids + ordered(mode).filter { !d.ids.contains($0) })
        withAnimation(.easeOut(duration: 0.15)) { cardDrag = nil }
        log("card: \(mode) top five \(d.ids)")
        if !overCard && !overButton { scheduleHide() }
        return true
    }

    static let halfLife: Double = 3 * 86400

    /// An app of one mode has one count. A shared app has one for each mode, so it can earn a place
    /// on one mode's card and not on another's.
    func use(_ id: String, _ mode: String) -> Use? {
        isShared(id) ? state.sharedUsage?[mode]?[id] : state.usage?[id]
    }

    func setUse(_ use: Use?, _ id: String, _ mode: String) {
        if isShared(id) {
            var shared = state.sharedUsage ?? [:]
            shared[mode, default: [:]][id] = use
            state.sharedUsage = shared
        } else {
            var usage = state.usage ?? [:]
            usage[id] = use
            state.usage = usage
        }
    }

    func score(_ id: String, _ mode: String, now: Date = Date()) -> Double {
        guard let u = use(id, mode) else { return 0 }
        return u.score * pow(0.5, now.timeIntervalSince(u.at) / DockModel.halfLife)
    }

    /// An app brought forward counts once per two minutes. The order you give the card stays, but
    /// an app used well more than the least used of its mode's top five (twice as much, and three
    /// uses more) takes that one's place; the other four keep theirs.
    func used(_ id: String) {
        guard let mode = isShared(id) ? state.current : owner(id) else { return }
        let now = Date()
        if let u = use(id, mode), now.timeIntervalSince(u.at) < 120 { return }
        setUse(Use(score: score(id, mode, now: now) + 1, at: now), id, mode)
        var list = ordered(mode)
        if let i = list.firstIndex(of: id), i >= 5,
           let weakest = list.indices.prefix(5).min(by: { score(list[$0], mode) < score(list[$1], mode) }),
           score(id, mode) >= 2 * score(list[weakest], mode) + 3 {
            let out = list[weakest]
            list.remove(at: i)
            list[weakest] = id
            list.insert(out, at: 5)
            log("card: \(id) overtakes \(out) in \(mode)'s top five")
            saveOrder(mode, list)
            return
        }
        writeJSON(stateURL, state)
    }

    /// Put an app in its mode's top five, as the fifth, or take it out to the end of the list. One
    /// taken out starts its use over, so it climbs back only by being used anew. A shared app taken
    /// out leaves the mode's list altogether.
    func setOnCard(_ id: String, _ mode: String, _ on: Bool) {
        if !on { setUse(nil, id, mode) }
        var list = ordered(mode).filter { $0 != id }
        if on { list.insert(id, at: min(4, list.count)) } else if !isShared(id) { list.append(id) }
        saveOrder(mode, list)
    }

    /// Apps moved to another mode keep their place in this one's list, so moving one back puts it
    /// where it was. A shared app taken off the card has no other mode, and leaves.
    func saveOrder(_ mode: String, _ list: [String]) {
        var o = state.order ?? [:]
        var next = list
        for (i, id) in (o[mode] ?? []).enumerated() where !next.contains(id) {
            if let other = owner(id), other != mode { next.insert(id, at: min(i, next.count)) }
        }
        o[mode] = next
        state.order = o
        writeJSON(stateURL, state)
    }

    init() {
        let config = loadConfig()
        var s = readJSON(stateURL, SavedState.self) ?? SavedState(current: config.modes.first?.name ?? "")
        if !config.modes.contains(where: { $0.name == s.current }) { s.current = config.modes.first?.name ?? "" }
        for key in s.apps.keys { s.apps[key]?.removeAll(where: config.alwaysVisible.contains) }   // a shared app has no mode
        // Nor has a browser that is not pinned: a state that gave it a mode keeps what it counted
        // there as that mode's count for it (its place on the card is in `order` already).
        for (mode, ids) in s.apps {
            for id in ids where sharedByDefault(id, config) && !config.modes.contains(where: { $0.apps?.contains(id) ?? false }) {
                s.apps[mode]?.removeAll { $0 == id }
                var shared = s.sharedUsage ?? [:]
                if shared[mode]?[id] == nil, let u = s.usage?[id] { shared[mode, default: [:]][id] = u }
                s.sharedUsage = shared
            }
        }
        state = s
        scale = s.scale ?? 1
        ready = s.gateReady.flatMap { r in config.modes.contains { $0.name == r } ? r : nil }
        if let p = s.gatePending, let d = s.gateDeadline, config.modes.contains(where: { $0.name == p }) {
            pending = p   // the wait runs on through restarts; tick() ends it once it is due
            deadline = d
            gateTotal = s.gateTotal ?? max(1, d.timeIntervalSinceNow)
            remaining = max(0, d.timeIntervalSinceNow)
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    // A launch or quit changes the list; an activation only if the app is new to it.
                    if name == NSWorkspace.didLaunchApplicationNotification || name == NSWorkspace.didTerminateApplicationNotification
                        || (name == NSWorkspace.didActivateApplicationNotification && app.map { self?.regularApps.contains($0) == false } == true) {
                        self?.refreshRegular()
                    }
                    if let app {
                        if name == NSWorkspace.didTerminateApplicationNotification, self?.tracked(app) != nil {
                            self?.quitAt = Date()
                        }
                        if name == NSWorkspace.didActivateApplicationNotification {
                            self?.activated(app)
                            self?.lastFront = app
                        }
                        if name == NSWorkspace.didLaunchApplicationNotification {
                            self?.refreshInstalled()
                            self?.launchedAt[app.processIdentifier] = Date()
                            self?.appeared(app, launched: true)
                        }
                        if name == NSWorkspace.didUnhideApplicationNotification { self?.appeared(app, launched: false) }
                        if name == NSWorkspace.didTerminateApplicationNotification {
                            self?.launchedAt[app.processIdentifier] = nil
                        }
                    }
                    self?.refresh()
                }
            }
        }
        refreshRegular()
        clearsOrder = objectWillChange.sink { [weak self] in self?.orderCache = [:] }
        for app in visibleApps() { enforce(app) }
        refreshInstalled()
        every(60) { [weak self] in self?.refreshRegular(); self?.refreshInstalled() }
        refresh()
        ticker = every(0.25) { [weak self] in self?.tick() }
        every(2) { [weak self] in self?.settle() }
    }

    var currentMode: Mode? { config.modes.first { $0.name == state.current } }
    private var settles = 0

    /// The running apps with a Dock icon. Every read of an NSRunningApplication asks its process
    /// again, so the hundred or so processes are walked at a launch, quit or activation (which
    /// also catches an app that changed its policy) rather than every time a list is wanted.
    private(set) var regularApps: [NSRunningApplication] = []
    func refreshRegular() {
        let me = ProcessInfo.processInfo.processIdentifier
        let next = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        if next != regularApps { regularApps = next; orderCache = [:] }
    }

    /// Visible regular apps with a real window: what the current mode holds right now. An app
    /// without windows (a browser an automation tool started, say) has nothing to show or hide.
    func visibleApps() -> [NSRunningApplication] {
        let windowed = windowOwners()
        return regularApps.filter {
            windowed.contains($0.processIdentifier) && !$0.isTerminated && !$0.isHidden && !isShared($0.bundleIdentifier ?? "")
        }.sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
    }

    /// Apps with a real window. Listing every window costs a few milliseconds, more under load,
    /// and one event often asks several times, so the answer is kept for a third of a second.
    var owners: (at: Date, pids: Set<pid_t>)?
    func windowOwners() -> Set<pid_t> {
        if let o = owners, Date().timeIntervalSince(o.at) < 0.3 { return o.pids }
        let pids = listWindowOwners()
        owners = (Date(), pids)
        return pids
    }

    func listWindowOwners() -> Set<pid_t> {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return Set(list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  (b["Width"] ?? 0) > 60, (b["Height"] ?? 0) > 60 else { return nil }
            return w[kCGWindowOwnerPID as String] as? pid_t
        })
    }

    /// Shared apps first (running, hidden or not), then the current mode's visible apps.
    func dockApps() -> [NSRunningApplication] {
        let shared = regularApps.filter { !$0.isTerminated && isShared($0.bundleIdentifier ?? "") }
        let order = config.alwaysVisible
        let rank = { (a: NSRunningApplication) in order.firstIndex(of: a.bundleIdentifier ?? "") ?? Int.max }
        let ordered = shared.sorted { (rank($0), $0.launchDate ?? .distantPast) < (rank($1), $1.launchDate ?? .distantPast) }
        var seen = Set<String>()   // one icon per shared app, however many processes it runs
        // This mode's apps only, and during a switch the ones on their way in: the row changes
        // once, with the mode, instead of an icon at a time as each hide and show lands.
        let windowed = windowOwners()
        let comingIn = regularApps.filter {
            incoming.contains($0.bundleIdentifier ?? "") && $0.isHidden && windowed.contains($0.processIdentifier)
        }
        let mine = (visibleApps() + comingIn).filter { a in
            let o = owner(a.bundleIdentifier ?? "")
            return o == nil || o == state.current
        }.sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        return ordered.filter { seen.insert($0.bundleIdentifier ?? "").inserted } + mine
    }

    var incoming: Set<String> = []   // apps a switch is bringing back, until it has settled
    var switchCount = 0

    /// Shared with every mode: named in alwaysVisible, or a browser or web app not pinned to one mode.
    func isShared(_ id: String) -> Bool {
        config.alwaysVisible.contains(id) || sharedByDefault(id, config) && pinned(id) == nil
    }

    /// Fix an app to one mode in the config (or to none).
    func pin(_ id: String, to mode: String?) {
        for i in config.modes.indices {
            config.modes[i].apps?.removeAll { $0 == id }
            if config.modes[i].name == mode { config.modes[i].apps = (config.modes[i].apps ?? []) + [id] }
        }
        writeJSON(configURL, config)
    }

    /// Publishes only what changed, since each publish redraws the dock.
    func refresh() {
        let next = dockApps()
        if next.map(\.processIdentifier) != apps.map(\.processIdentifier) { apps = next }
        let f = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if f != frontmost { frontmost = f }
        DispatchQueue.main.async { self.onChange?() }
    }

    func reloadConfig() {
        config = loadConfig()
        refreshInstalled()
        onAddIns?()
        if currentMode == nil, let first = config.modes.first { state.current = first.name; writeJSON(stateURL, state) }
        refresh()
    }

    // MARK: Switching

    func tap(_ name: String) {
        guard !justDragged else { return }
        log("tap \(name) (in \(state.current), pending \(pending ?? "-"), pomo \(state.pomoPhase ?? "idle"))")
        guard let mode = config.modes.first(where: { $0.name == name }) else { return }
        // The rules are GateCore's (tests/gate-tests.swift). In short: the wait for a gated mode runs
        // on wherever you are; going back within 5 s of leaving it needs no wait; a break or a pause
        // opens it at once. During focus each burst of clicks starts with three that only warn (the
        // button blinks red, a halo around the pomodoro says a round is on), and each click after
        // those cuts 20% of the wait: from 25 minutes clicking alone takes about 30 to get in. (A
        // third a click opened it after seconds of fast clicking, and 5% took about a hundred,
        // too strict; both 8 November. 15%, about 40, was still too slow.)
        let now = Date()
        let outcome = GateCore.tap(.init(name: name, current: state.current, gated: mode.gate != nil, unblocked: unblocked,
                                         focus: state.pomoPhase == "focus", ready: ready, leftGated: leftGated,
                                         pending: pending, deadline: deadline, nudges: nudges, nudgedAt: nudgedAt, now: now))
        if state.pomoPhase == "focus", mode.gate != nil, !unblocked, ![.stay, .open, .back].contains(outcome) {
            if now.timeIntervalSince(nudgedAt) > GateCore.clickPause { nudges = 0 }
            nudgedAt = now
        }
        switch outcome {
        case .stay:
            return
        case .open:
            if mode.gate != nil { cancelGate() }   // a break or a pause opens a gated mode at once
            switchTo(name)
            return
        case .back:
            log("  back to \(name) within \(Int(now.timeIntervalSince(leftGated?.at ?? now))) s of leaving it")
            leftGated = nil
            nudges = 0
            switchTo(name)
            return
        case .nudge(let n):
            nudges = n
            nudge += 1
            denied[name, default: 0] += 1
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            log("  nudge \(n)/\(GateCore.warnings): focus has \(Int(pomoLeft)) s left")
            if pending != name, launchOnOpen?.mode == name { launchOnOpen = nil }   // a warning holds no app for later
            return
        case .cut(let next):
            deadline = now.addingTimeInterval(next)
            remaining = next
            clickedAt = now
            saveGate()
            return
        case .start:
            break
        }
        guard let g = mode.gate else { return }
        cancelGate()
        // Asking for a gated mode starts a focus round if none is set; the wait is the round's
        // time left, so left alone the mode opens when the break begins. Clicks cut only the
        // wait; the pomodoro keeps its own time.
        if state.pomoPhase == nil { startPlan() }
        pending = name
        gateTotal = max(1, focusRunning ? pomoLeft : g.startMinutes * 60)
        remaining = gateTotal
        deadline = Date().addingTimeInterval(gateTotal)
        clickedAt = Date()
        saveGate()
        onChange?()
    }

    @Published var nudge = 0      // bumped on each nudge; the pomodoro's halo plays on a change
    @Published var denied: [String: Int] = [:]   // bumped on each nudge; the gated mode's button blinks red
    var nudges = 0
    var nudgedAt = Date.distantPast
    var leftGated: (mode: String, at: Date)?   // the gated mode just left, and when

    func saveGate() {
        state.gatePending = pending
        state.gateDeadline = deadline
        state.gateTotal = pending == nil ? nil : gateTotal
        state.gateReady = ready
        writeJSON(stateURL, state)
    }

    func tick() {
        // The round's end first: a wait that runs out with it is the break's to open.
        if let end = state.pomoEnd, end.timeIntervalSinceNow <= 0 { pomoPhaseEnded() }
        // Only steady clicking gets in: 5 s without a click puts the wait back to the round's end,
        // unless you asked for an app of the mode and under a minute is left: that runs out and opens it.
        if pending != nil, let d = deadline,
           GateCore.resets(deadline: d, roundEnd: state.pomoEnd, focusRunning: focusRunning, clickedAt: clickedAt,
                           holds: holdsApp(d), now: Date()), let end = state.pomoEnd {
            log("  no click for \(Int(GateCore.clickPause)) s: the wait for \(pending ?? "-") is back to \(Int(pomoLeft)) s")
            deadline = end
            gateTotal = max(1, pomoLeft)
            remaining = gateTotal
            saveGate()
        }
        if let d = deadline, let name = pending {
            let r = max(0, d.timeIntervalSinceNow)
            if r <= 0 { waitOver(name); return }
            // Redraw only when the label or the ring would visibly move.
            if r.rounded(.up) != remaining.rounded(.up) || abs(r - remaining) / max(1, gateTotal) > 0.004 { remaining = r }
        }
        // SwiftUI can drop a drag without ending it (the panel resized under it, say). Left so, the
        // dock would count as dragging for good and take no more clicks.
        if dragging, NSEvent.pressedMouseButtons & 1 == 0, Date().timeIntervalSince(dragSeen) > 0.5 {
            log("drag: the mouse is up but the drag never ended; ending it")
            dragEnded(drop: false)
        }
        if cardDrag != nil, NSEvent.pressedMouseButtons & 1 == 0, Date().timeIntervalSince(cardDragSeen) > 0.5 {
            log("card: the mouse is up but the drag never ended; ending it")
            if let mode = hovered { _ = cardDragEnded(mode) } else { cardDrag = nil }
        }
        // The clock redraws the pomodoro and the mode buttons. The pomodoro's label moves once a
        // minute and its ring about a pixel in 7 s, so the clock ticks every 5 s; every second only
        // for a gate's wait, a round's last minute and the 10 s after a click (a mode's ring).
        let s = Int(Date().timeIntervalSince1970)
        let fine = pending != nil || (pomoRunning && pomoLeft < 61) || Date().timeIntervalSince(clickedAt) < 11
        if s != ticks.second, fine || s % 5 == 0 { ticks.second = s }
    }

    /// A wait ran out, or a break began during it. It opens the mode only while you are still
    /// asking for it, with a click in the last 5 s. Otherwise you have gone back to work: the
    /// mode stays shut and the next click opens it (during focus; a break opens it anyway).
    /// An app asked for from the mode's card, with under a minute of the wait left at `deadline`.
    /// The app that opens with the gated mode when its wait runs out, if one is held.
    var heldApp: String? {
        guard let d = deadline, let l = launchOnOpen, l.mode == pending, holdsApp(d) else { return nil }
        return l.id
    }

    func holdsApp(_ deadline: Date) -> Bool {
        GateCore.holdsApp(launchFor: launchOnOpen?.mode, pending: pending, deadline: deadline, clickedAt: clickedAt)
    }

    func waitOver(_ name: String) {
        let asking = GateCore.asking(clickedAt: clickedAt, holds: deadline.map(holdsApp) == true, now: Date())
        let launch = launchOnOpen
        cancelGate()
        if asking {
            launchOnOpen = launch
            switchTo(name)
        } else {
            if !unblocked { ready = name }
            saveGate()
            log("wait for \(name) over, last click \(Int(Date().timeIntervalSince(clickedAt))) s ago: \(unblocked ? "the break or pause opens it" : "the next click opens it")")
        }
    }

    func cancelGate() {
        if pending != nil, launchOnOpen?.mode == pending { launchOnOpen = nil }
        let had = pending != nil
        deadline = nil
        pending = nil
        remaining = 0
        if had { saveGate() }
        DispatchQueue.main.async { self.onChange?() }
    }

    // MARK: Ownership

    func pinned(_ id: String) -> String? { config.modes.first { $0.apps?.contains(id) ?? false }?.name }

    func owner(_ id: String) -> String? {
        pinned(id) ?? config.modes.first { state.apps[$0.name]?.contains(id) ?? false }?.name
    }

    /// Record that the app belongs to the mode, and to no other.
    func claim(_ id: String, for mode: String) {
        for key in state.apps.keys { state.apps[key]?.removeAll { $0 == id } }
        if pinned(id) == nil || pinned(id) == mode { state.apps[mode, default: []].append(id) }
    }

    func tracked(_ app: NSRunningApplication) -> String? {
        guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !isShared(id), !Apps.headless(app.processIdentifier) else { return nil }
        return id
    }

    /// Activations the dock's own switch causes (hiding the front app hands focus to another).
    var quietUntil = Date.distantPast
    /// Quitting an app hands the front to another, Finder when nothing else shows. That is macOS
    /// choosing, not you: on 4 November quitting Notes in one mode brought Finder up and took the
    /// dock to Finder's mode. Such an app is not followed while it stays in front.
    var quitAt = Date.distantPast
    var fallback: pid_t?
    var lastFront: NSRunningApplication?   // the app in front before this activation
    var launchedAt: [pid_t: Date] = [:]    // when each app launched, while it runs
    var afterQuit: Bool { Date().timeIntervalSince(quitAt) < 1.5 || lastFront?.isTerminated == true }
    func justLaunched(_ app: NSRunningApplication) -> Bool {
        Date().timeIntervalSince(launchedAt[app.processIdentifier] ?? .distantPast) < 5
    }

    /// You brought an app forward (Cmd-Tab, the macOS Dock, a notification): follow it to its
    /// mode. A gated mode's app is hidden again instead, unless the pomodoro is on a break.
    /// A shared app has no mode to follow: it only counts as used in the mode you are in, unless
    /// macOS brought it up, as a switch's hides and a quit do with Finder.
    func activated(_ app: NSRunningApplication, recheck: Bool = true) {
        let shared = app.activationPolicy == .regular && isShared(app.bundleIdentifier ?? "")
        guard let id = shared ? app.bundleIdentifier : tracked(app), !app.isTerminated else { return }
        // Only the app in front now counts: an activation told late, after another app took the
        // front, is old news. The app's own isHidden is no guide, as it can lag its activation.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            if recheck {   // the front may be told a moment after the activation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                    self.activated(app, recheck: false)
                }
            }
            return
        }
        if shared {
            if expecting(id) || (Date() >= quietUntil && !afterQuit) { used(id) }
            return
        }
        guard let other = owner(id) else {
            log("claim \(id) for \(state.current)")
            claim(id, for: state.current)
            used(id)
            return
        }
        if app.processIdentifier != fallback { fallback = nil }
        guard other != state.current, Date() >= quietUntil else { if other == state.current { used(id) }; return }
        if app.processIdentifier == fallback { return }
        // The quit may be told before or after the app it hands the front to. An app just launched,
        // or one the dock is opening, is never macOS's pick: you asked for it.
        if !justLaunched(app), !expecting(id), afterQuit {
            fallback = app.processIdentifier
            let next = visibleApps().last { owner($0.bundleIdentifier ?? "") == state.current }
            log("after a quit macOS brought \(id) forward: staying in \(state.current)\(next.map { ", focus \($0.bundleIdentifier ?? "?")" } ?? "")")
            if let next { Vis.focus(next) }
            return
        }
        if config.modes.first(where: { $0.name == other })?.gate != nil,
           !GateCore.followAllowed(mode: other, unblocked: unblocked, ready: ready, leftGated: leftGated, now: Date()) {
            log("blocked \(id): \(other) waits for a break")
            Vis.set([app], visible: false)
            denied[other, default: 0] += 1   // opened from Raycast or elsewhere: its button blinks red
            return
        }
        log("follow \(id) to \(other)")
        state.focus[other] = id
        switchTo(other)
        used(id)
    }

    /// An app launched or unhidden without being brought forward stays out of other modes. A
    /// launch is given three seconds to come to the front, since a big app opened from Raycast or
    /// Finder can take that long; coming forward, it takes the dock to its mode instead.
    func appeared(_ app: NSRunningApplication, launched: Bool) {
        guard let id = tracked(app), owner(id) != nil, !expecting(id) else { return }
        let deadline = Date().addingTimeInterval(launched ? 3 : 0.6)
        func check() {
            guard !app.isTerminated, !app.isHidden, !expecting(id), let other = owner(id), other != state.current,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else { return }
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { check() } }
                return
            }
            guard Date() >= quietUntil else { return }   // the switch under way hides what it must
            log("hide \(id): \(launched ? "launched" : "appeared") outside \(other) and stayed behind")
            Vis.set([app], visible: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { check() } }
    }

    /// Every two seconds, and once a switch has settled: the app in front follows to its mode (or is
    /// hidden, for a gated one), and any other app of another mode that is showing is hidden. So
    /// an app that came up while the dock was busy switching never stays in the wrong mode.
    func settle() {
        settles += 1
        // Listing every window is most of its cost: idle, once in 10 s is enough.
        guard Date() >= quietUntil, !dragging, idleSeconds < 10 || settles % 5 == 0 else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if let front, let id = tracked(front), let other = owner(id), other != state.current {
            activated(front)
            return
        }
        // Only an app of another mode, or of none yet, has anything to enforce, so the window list
        // (most of the cost) is read only while one is showing.
        let strays = regularApps.filter { a in
            let id = a.bundleIdentifier ?? ""
            return a.processIdentifier != front?.processIdentifier && owner(id) != state.current && !isShared(id)
                && !a.isTerminated && !a.isHidden
        }
        // One found without a window (WhatsApp closed to its menu, say) is looked at again in 10 s.
        let now = Date()
        let due = strays.filter { (windowless[$0.processIdentifier] ?? .distantPast) <= now }
        guard !due.isEmpty else { return }
        let windowed = windowOwners()
        for app in due {
            if windowed.contains(app.processIdentifier) { enforce(app) } else { windowless[app.processIdentifier] = now + 10 }
        }
    }
    private var windowless: [pid_t: Date] = [:]

    /// A new app joins the current mode, another mode's app is hidden.
    func enforce(_ app: NSRunningApplication) {
        guard let id = tracked(app), !expecting(id) else { return }
        if owner(id) != nil, owner(id) != state.current, justLaunched(app) { return }   // appeared() decides
        switch owner(id) {
        case nil:
            log("claim \(id) for \(state.current)")
            claim(id, for: state.current)
            writeJSON(stateURL, state)
        case state.current?:
            break
        default:
            log("enforce: hide \(id) (belongs to \(owner(id) ?? "-"), in \(state.current))")
            Vis.set([app], visible: false)
        }
    }

    /// Move an app to another mode for good: it leaves the config's fixed list if it was on one.
    func moveApp(_ app: NSRunningApplication, to mode: String) {
        guard let id = app.bundleIdentifier else { return }
        let onCard = owner(id).map { preview($0).contains(id) } ?? false   // before a pin changes the owner
        if config.alwaysVisible.contains(id) {
            config.alwaysVisible.removeAll { $0 == id }
            writeJSON(configURL, config)
        }
        if sharedByDefault(id, config) {
            pin(id, to: mode)   // a browser or web app leaves the shared set only by being pinned
        } else if let p = pinned(id), p != mode {
            pin(id, to: nil)
        }
        log("move \(id) to \(mode)")
        claim(id, for: mode)
        // Its old place on this mode's card comes back with it; failing that, an app from the old
        // card goes on this one, as the fifth, not last behind every app ordered here.
        if onCard && !preview(mode).contains(id) { setOnCard(id, mode, true) } else { writeJSON(stateURL, state) }
        refresh()
    }

    /// The running apps the dock menu can share with every mode, or take back: one row an app.
    func shareable() -> [NSRunningApplication] {
        var seen = Set<String>()
        return regularApps.filter {
            guard !$0.isTerminated, let id = $0.bundleIdentifier, id != finderID, $0.activationPolicy == .regular,
                  $0.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !Apps.headless($0.processIdentifier) else { return false }
            return seen.insert(id).inserted
        }.sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    /// Share an app with every mode.
    func share(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, !isShared(id) else { return }
        let from = owner(id), count = state.usage?[id]
        pin(id, to: nil)
        if !sharedByDefault(id, config) {
            config.alwaysVisible.append(id)
            writeJSON(configURL, config)
        }
        if let from, let count { setUse(count, id, from) }   // its use so far was all in that mode
        for key in state.apps.keys { state.apps[key]?.removeAll { $0 == id } }
        writeJSON(stateURL, state)
        log("share \(id) with every mode")
        refresh()
    }

    /// Go to a mode. `bring` is an app you asked for (from the card, or held for a gated mode):
    /// it comes up in front, launched or reopened if need be, instead of the mode's last front app.
    func switchTo(_ target: String, bring: String? = nil) {
        var bring = bring
        if let l = launchOnOpen, l.mode == target {
            launchOnOpen = nil
            bring = bring ?? l.id
        }
        if let bring { expect(bring) }
        if pending == target { cancelGate() }   // however you got there, the wait for it is over
        closeCard()
        if ready == target { ready = nil; saveGate() }
        leftGated = currentMode?.gate != nil && target != state.current ? (state.current, Date()) : nil
        let leaving = visibleApps()
        let leavingIds = leaving.compactMap(\.bundleIdentifier)
        for id in leavingIds where owner(id) == nil { claim(id, for: state.current) }
        if let f = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, leavingIds.contains(f) {
            state.focus[state.current] = f
        }
        let wanted = Set((state.apps[target] ?? []) + (config.modes.first { $0.name == target }?.apps ?? []))
        // What comes back next time: every app showing, or with Rectangle the app in front and
        // every app placed in a Rectangle field. Measured on the Accessibility queue before the
        // hides queued below, while every window is up.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let tiles = active(\.rectangle), areas = tiles ? Tiles.areas() : [], from = state.current
        // Only the mode's own apps: one of another mode, showing for a moment, is not its to keep.
        let candidates = leaving.filter { owner($0.bundleIdentifier ?? "") == from }
            .map { ($0.processIdentifier, $0.bundleIdentifier ?? "") }
        let kept = Bag<String>()
        for c in candidates {
            if !tiles { kept.add(c.1); continue }
            Vis.onApp(c.0) { if c.1 == front || Tiles.placed(c.0, areas) { kept.add(c.1) } }
        }
        Vis.afterQueued { [weak self] in
            guard let self else { return }
            let keep = Set(kept.all).sorted()
            var shown = self.state.shown ?? [:]
            shown[from] = keep
            self.state.shown = shown
            writeJSON(stateURL, self.state)
            log("  \(from) brings back \(keep) next time")
        }
        let shown = state.shown ?? [:]
        log("switch \(state.current) -> \(target): leaving \(leavingIds)")
        if config.modes.first(where: { $0.name == target })?.gate != nil { state.returnTo = state.current }
        let leftMode = state.current
        state.current = target
        writeJSON(stateURL, state)
        if addIn(\.hooks) { Hooks.run(from: leftMode, to: target, gated: config.modes.first { $0.name == target }?.gate != nil) }
        // All at once: the apps that come back, then the front one on top, then the old mode leaves.
        let focus = bring ?? state.focus[target].flatMap { wanted.contains($0) && !Apps.running($0).isEmpty ? $0 : nil }
            ?? (shown[target] ?? []).first { wanted.contains($0) && !Apps.running($0).isEmpty }
            ?? wanted.sorted().first { !Apps.running($0).isEmpty }
        let back = (shown[target] ?? []).filter { wanted.contains($0) && $0 != focus }
        log("  focus \(focus ?? "none"), with \(back)")
        quietUntil = Date().addingTimeInterval(1.0)
        incoming = Set(back + [focus].compactMap { $0 })
        switches += 1
        refresh()   // the dock row and the mode buttons change now, with the click
        let going = leaving.filter { !wanted.contains($0.bundleIdentifier ?? "") }
        // The apps that come back and the front one on top first, and only once that one is up
        // (or a fifth of a second has gone) the old mode leaves: hiding first showed the desktop for
        // a moment (AeroSpace, layout/refresh.swift: "first unhide visible workspaces, then hide").
        Vis.set(back.flatMap(Apps.running), visible: true)
        if let bring { Apps.bringUp(bring) } else if let focus { Vis.focus(focus) }
        switchCount += 1
        let n = switchCount, since = Date()
        func hideOld() {
            guard n == switchCount else { return }   // a newer switch decides what shows now
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if focus != nil, front != focus, Date().timeIntervalSince(since) < 0.2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { MainActor.assumeIsolated { hideOld() } }
                return
            }
            Vis.set(going.filter { owner($0.bundleIdentifier ?? "") != state.current }, visible: false)
        }
        hideOld()
        // Under load the queues may take longer than the second above: stay quiet until they
        // have run, then sweep once the hides have settled.
        Vis.afterQueued { [weak self] in
            guard let self else { return }
            self.quietUntil = max(self.quietUntil, Date().addingTimeInterval(0.5))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in self?.settle() }
        }
        settled(focus: focus, since: Date(), switch: switches)
    }
    private var switches = 0

    /// The swap has landed when every hide and show has been made and the front app is up (or
    /// half a second has gone by): the dock row then shows what is really there.
    func settled(focus: String?, since: Date, switch n: Int) {
        guard n == switches else { return }   // a later switch has its own and owns `incoming`
        let t = Date().timeIntervalSince(since)
        let up = focus == nil || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == focus || t > 0.5
        if (Vis.idle && up) || t > 1.2 {
            incoming = []
            refresh()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.settled(focus: focus, since: since, switch: n) }
    }

    // MARK: Pomodoro

    var pomo: Pomodoro { config.pomodoro ?? Pomodoro(focusMinutes: 25, breakMinutes: 5) }
    var onBreak: Bool { state.pomoPhase == "break" && state.pomoEnd != nil }
    var paused: Bool { state.pomoPhase != nil && state.pomoEnd == nil }
    /// On a break or with the timer paused, nothing is held back: a gated mode opens at once, its
    /// apps show anywhere, the browsers block no site and Raycast lists every app.
    var unblocked: Bool { onBreak || paused }
    var pomoRunning: Bool { state.pomoEnd != nil }
    var focusRunning: Bool { state.pomoPhase == "focus" && pomoRunning }
    var plan: [PomoBlock] { pomo.plan }
    /// Where the plan stands. Past the last block it is done; idle on a later day it starts over.
    var pomoBlock: Int { state.pomoPhase == nil && state.pomoDay != today ? 0 : state.pomoBlock ?? 0 }
    var pomoLength: Double { plan[pomoBlock].minutes * 60 }
    var pomoLeft: Double {
        if let end = state.pomoEnd { return max(0, end.timeIntervalSinceNow) }
        return state.pomoLeft ?? pomo.focusMinutes * 60
    }
    var pomoCount: Int { state.pomoDay == today ? (state.pomoCount ?? 0) : 0 }
    var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func pomoTap() {
        guard !justDragged else { return }
        if let end = state.pomoEnd {                       // running: pause, which holds nothing back
            state.pomoLeft = max(0, end.timeIntervalSinceNow)
            state.pomoEnd = nil
            if let p = pending { waitOver(p) }
        } else if let left = state.pomoLeft {              // paused: resume
            state.pomoEnd = Date().addingTimeInterval(left)
            state.pomoLeft = nil
            if state.pomoPhase == "focus" { leaveGatedMode() }   // as when a round of focus starts
        } else {                                           // idle: start focusing, out of a gated mode
            startPlan()
            leaveGatedMode()
        }
        writeJSON(stateURL, state)
        ticks.second = 0
    }

    /// From idle: the plan's next focus round. A new day or a finished plan starts from the first.
    func startPlan() {
        let from = pomoBlock
        state.pomoCount = pomoCount   // before the day moves: yesterday's rounds are not today's
        state.pomoDay = today
        begin(plan[from...].firstIndex { $0.kind == .focus } ?? 0)
    }

    func begin(_ block: Int) {
        if ready != nil { ready = nil; saveGate() }   // an opened mode lasts to the end of its round
        state.pomoBlock = block
        state.pomoPhase = plan[block].kind == .focus ? "focus" : "break"
        if state.pomoPhase == "focus" { leftGated = nil }   // and so does the way straight back into it
        state.pomoLeft = nil
        state.pomoEnd = Date().addingTimeInterval(plan[block].minutes * 60)
        writeJSON(stateURL, state)
        onChange?()
    }

    /// Skipping to a break frees a gated mode and leaves you where you are, even with a click on it
    /// a moment ago: the wait just ends, and during the break a click opens the mode at once.
    func pomoSkip() {
        let next = pomoBlock + 1
        log("pomodoro: skip from block \(pomoBlock) of \(plan.count) (in \(state.current), pending \(pending ?? "-"))")
        guard next < plan.count else { stopPlan(at: next); return }
        begin(next)
        if plan[next].kind == .focus { leaveGatedMode() } else { cancelGate() }
    }

    /// The plan is over, or the Mac slept past the next block: stop with the plan standing at `at`.
    func stopPlan(at block: Int) {
        state.pomoBlock = block
        pomoReset()
    }

    /// Reset stops the round and the wait it set. With the timer stopped a gated mode is shut (a
    /// click on it starts a round and its wait), so Reset leaves it, as the end of the plan does.
    func pomoReset() {
        cancelGate()
        if ready != nil { ready = nil; saveGate() }
        state.pomoPhase = nil
        state.pomoEnd = nil
        state.pomoLeft = nil
        writeJSON(stateURL, state)
        leaveGatedMode()
        onChange?()
    }

    func pomoPhaseEnded() {
        let next = pomoBlock + 1
        if state.pomoPhase == "focus" { state.pomoCount = pomoCount + 1; state.pomoDay = today }
        guard next < plan.count else {
            log("pomodoro: the day's plan is done")
            NSSound(named: "Submarine")?.play()
            stopPlan(at: next)
            return
        }
        // The Mac slept through the end and the next block would be over too: stop instead of
        // starting a round nobody is there for.
        let overdue = -(state.pomoEnd?.timeIntervalSinceNow ?? 0)
        if overdue > plan[next].minutes * 60 {
            log("pomodoro: block ended \(Int(overdue)) s ago, stopping")
            stopPlan(at: next)
            return
        }
        let toFocus = plan[next].kind == .focus
        NSSound(named: toFocus ? "Submarine" : "Glass")?.play()
        begin(next)
        if toFocus { leaveGatedMode() } else if let p = pending { waitOver(p) }   // the break ends a wait
    }

    /// A break is over: leave a gated mode for the one you came from.
    func leaveGatedMode() {
        guard currentMode?.gate != nil else { return }
        let back = state.returnTo.flatMap { r in config.modes.first { $0.name == r && $0.gate == nil } }
            ?? config.modes.first { $0.gate == nil }
        if let back { switchTo(back.name) }
        leftGated = nil   // the break is over: no way straight back
    }

    // MARK: Dragging

    var dragStart: (mouse: NSPoint, x: Double)?
    var position: (() -> Double)?
    var move: ((Double) -> Void)?
    var layoutNow: (() -> Void)?
    /// True from a drag's first move until a moment after it ends: a button under the pointer
    /// when the mouse comes up after a drag must not count it as a click.
    var dragging: Bool { draggedApp != nil || dragStart != nil || resizing != nil || movingDock }
    var dragEndedAt = Date.distantPast
    var justDragged: Bool { dragging || Date().timeIntervalSince(dragEndedAt) < 0.35 }

    func setScale(_ k: Double, save: Bool = true) {
        let new = max(0.6, min(1.8, k))
        // The dock lays itself out at the new size a moment later; until then its size is the old
        // one in proportion, so the panel grows in this same step and nothing is cut off.
        if natural != .zero, scale > 0, new != scale {
            natural = CGSize(width: natural.width * new / scale, height: natural.height * new / scale)
        }
        scale = new
        layoutNow?()   // size the panel in the same step, so the scaled content is never clipped
        if save { state.scale = scale; writeJSON(stateURL, state) }
    }

    // Dragging an app icon carries the app to another mode.
    @Published var draggedApp: NSRunningApplication?
    @Published var dropTarget: String?
    var appFrames: [pid_t: CGRect] = [:]     // each app icon, in the dock's coordinates
    var movingDock = false
    var dragSeen = Date.distantPast           // the drag's last move
    var onAppDrag: ((NSImage?) -> Void)?      // the icon that follows the mouse, nil when it ends

    /// The mode an icon dropped here goes to: the nearest mode button, anywhere left of the app
    /// icons and up to 150 pt above the dock, so a drop need not land on the small button itself.
    /// The mode the app is in already is no target.
    func modeTarget(at p: CGPoint, for app: NSRunningApplication) -> String? {
        guard let lo = modeFrames.values.map(\.minX).min(), let hi = modeFrames.values.map(\.maxX).max(),
              p.x > lo - 60 * scale, p.x < hi + 24 * scale, p.y > -150 * scale else { return nil }
        let nearest = modeFrames.min { abs($0.value.midX - p.x) < abs($1.value.midX - p.x) }?.key
        return nearest == owner(app.bundleIdentifier ?? "") ? nil : nearest
    }

    func dragChanged(start: CGPoint, at point: CGPoint) {
        if draggedApp == nil, dragStart == nil, resizing == nil, !movingDock,
           let pid = appFrames.first(where: { $0.value.contains(start) })?.key,
           let app = NSRunningApplication(processIdentifier: pid),
           !isShared(app.bundleIdentifier ?? "") {   // a shared app moves only from its menu
            draggedApp = app
            closeCard()
            log("drag \(app.bundleIdentifier ?? "?")")
        }
        dragSeen = Date()
        if let app = draggedApp {
            let t = modeTarget(at: point, for: app)
            if t != dropTarget { dropTarget = t }
            onAppDrag?(app.icon ?? NSImage())
            return
        }
        movingDock = true
        dragChanged()
    }

    func dragChanged() {
        let m = NSEvent.mouseLocation
        // A drag that starts on the handle at the right end resizes; anywhere else it moves.
        if dragStart == nil, resizing == nil, let f = frame?(), Double(m.x) >= Double(f.maxX) - 34 * scale {
            resizing = (scale, Double(f.width), Double(m.x))
        }
        if let r = resizing {
            setScale(r.k * (r.width + Double(m.x) - r.mouse) / r.width, save: false)
            return
        }
        if dragStart == nil, let x = position?() { dragStart = (m, x); closeCard() }
        guard let d = dragStart else { return }
        move?(d.x + m.x - d.mouse.x)
    }

    /// `drop` is false for a drag whose gesture was lost: the app stays where it was.
    func dragEnded(drop: Bool = true) {
        dragEndedAt = Date()
        movingDock = false
        if let app = draggedApp {
            let target = drop ? dropTarget : nil
            draggedApp = nil
            dropTarget = nil
            onAppDrag?(nil)
            if let target, !app.isTerminated { moveApp(app, to: target) }
            else { log("drag \(app.bundleIdentifier ?? "?"): \(drop ? "dropped on no other mode" : "lost, cancelled")") }
            return
        }
        if resizing != nil { resizing = nil; setScale(scale); return }
        dragStart = nil
        if let x = position?() { state.dockLeft = x; writeJSON(stateURL, state) }
    }

    var recenter: (() -> Void)?

    var onAddIns: (() -> Void)?

    func addIn(_ key: WritableKeyPath<AddIns, Bool?>) -> Bool { config.addIns?[keyPath: key] ?? true }

    /// The add-ins' apps found on this Mac, by bundle id: looked up at start, when any app
    /// launches, on a config reload and every minute, so one installed later shows up by itself.
    @Published private(set) var installed: Set<String> = []

    func refreshInstalled() {
        let found = Set(AddIns.all.flatMap(\.apps).filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
        guard found != installed else { return }
        installed = found
        onAddIns?()
    }

    /// The add-in's app is here (or it needs none): it shows in the menu.
    func available(_ item: AddIns.Item) -> Bool { item.apps.isEmpty || item.apps.contains(where: installed.contains) }

    /// Switched on and its app installed.
    func active(_ key: WritableKeyPath<AddIns, Bool?>) -> Bool {
        addIn(key) && (AddIns.all.first { $0.key == key }.map(available) ?? true)
    }

    func setAddIn(_ key: WritableKeyPath<AddIns, Bool?>, _ on: Bool) {
        var a = config.addIns ?? AddIns()
        a[keyPath: key] = on
        config.addIns = a
        writeJSON(configURL, config)
        onAddIns?()
    }

    /// Back to the bottom of the screen, centred.
    func resetPosition() {
        guard !dragging else { return }
        state.dockLeft = nil
        writeJSON(stateURL, state)
        recenter?()
    }
}

// MARK: - Views

private struct DockScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    /// The dock's size: every length in its views is multiplied by it, so text and icons are drawn
    /// at the size they show at. Scaling the drawn dock instead blurred them on a 1x screen.
    var dockScale: CGFloat {
        get { self[DockScaleKey.self] }
        set { self[DockScaleKey.self] = newValue }
    }
}

struct DockView: View {
    @Environment(\.dockScale) private var k
    @ObservedObject var model: DockModel
    static let lift: CGFloat = 4
    /// The row's height at size 1: an app icon with its dot (38 + 3 + 4). The row keeps it with no
    /// app in it, so the dock is as tall in every mode and while a switch empties the row.
    static let row: CGFloat = 45
    /// From the lower screen edge to the top of the dock's body at size 1: lift, row and padding.
    static let bodyTop: CGFloat = lift + row + 2 * 8

    var body: some View {
        HStack(spacing: 10 * k) {
            Image(systemName: "line.3.horizontal")
                .rotationEffect(.degrees(90))
                .font(.system(size: 11 * k, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.35))
                .frame(width: 14 * k, height: 36 * k)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.resetPosition() }
                .help("Drag to move, double-click to centre at the bottom")
            HStack(spacing: 6 * k) {
                ForEach(model.config.modes, id: \.name) { mode in
                    ModeButton(mode: mode, model: model, ticks: model.ticks)
                }
            }
            if !model.apps.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 1, height: 30 * k)
                HStack(spacing: 6 * k) {
                    ForEach(model.apps, id: \.processIdentifier) { app in
                        AppIcon(app: app, model: model)
                    }
                }
            }
            if model.config.pomodoro != nil {
                Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 1, height: 30 * k)
                PomodoroView(model: model, ticks: model.ticks)
            }
            Capsule().fill(Color.primary.opacity(0.25))
                .frame(width: 3 * k, height: 18 * k)
                .frame(width: 8 * k, height: 36 * k)
                .contentShape(Rectangle())
                .help("Drag to resize")
        }
        .frame(minHeight: DockView.row * k)
        .padding(.horizontal, 10 * k)
        .padding(.vertical, 8 * k)
        .background(
            RoundedRectangle(cornerRadius: 22 * k, style: .continuous).fill(.ultraThinMaterial)
                .onTapGesture(count: 2) { model.resetPosition() }   // only where no button sits
        )
        .overlay(RoundedRectangle(cornerRadius: 22 * k, style: .continuous)
            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5 * k).allowsHitTesting(false))
        .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("dock"))
            .onChanged { v in model.dragChanged(start: v.startLocation, at: v.location) }
            .onEnded { _ in model.dragEnded() })
        .shadow(color: .black.opacity(0.3), radius: 10 * k, y: 2 * k)
        .padding([.top, .horizontal], 14 * k)   // shadow room
        .padding(.bottom, DockView.lift * k)    // stands just above the lower edge, like the macOS Dock
        .coordinateSpace(name: "dock")
        .contextMenu {
            Button("Edit Config…") { NSWorkspace.shared.open(configURL) }
            Button("Reload Config") { model.reloadConfig() }
            Button("Centre the Dock") { model.resetPosition() }
            Menu("Add-ins") {
                ForEach(AddIns.all.filter { model.available($0) }, id: \.title) { a in
                    Toggle(a.title, isOn: Binding(get: { model.addIn(a.key) }, set: { model.setAddIn(a.key, $0) }))
                }
                Divider()
                if AddIns.browsers.contains(where: { b in AddIns.all.contains { $0.key == b.key && model.available($0) } }) {
                    Button("Show Browser Extension Folder") { NSWorkspace.shared.open(ModeServer.extensionsFolder()) }
                }
                Button("Open Hooks Folder") { NSWorkspace.shared.open(Hooks.folder()) }
            }
            Menu("Apps in All Modes") {
                ForEach(model.shareable(), id: \.processIdentifier) { app in
                    Toggle(app.localizedName ?? app.bundleIdentifier ?? "?", isOn: Binding(
                        get: { model.isShared(app.bundleIdentifier ?? "") },
                        set: { $0 ? model.share(app) : model.moveApp(app, to: model.state.current) }))
                }
            }
            Menu("Size") {
                Button("Small") { model.setScale(0.8) }
                Button("Normal") { model.setScale(1) }
                Button("Large") { model.setScale(1.25) }
            }
            Divider()
            Button("Quit Anti-Dopamine Dock") { NSApp.terminate(nil) }
        }
    }
}

struct ScaledDock: View {
    @ObservedObject var model: DockModel

    /// The dock is laid out at its size: every length in its views is multiplied by the scale
    /// (`dockScale`), and the panel takes the size it comes to (`place`). It was drawn at size 1 and
    /// scaled up, which blurred text and icons on a 1x screen.
    var body: some View {
        DockView(model: model)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                if model.natural != size { model.natural = size }
                DispatchQueue.main.async { model.onChange?() }
            }
            .environment(\.dockScale, model.scale)
            .frame(width: model.natural == .zero ? nil : model.natural.width,
                   height: model.natural == .zero ? nil : model.natural.height,
                   alignment: .bottomLeading)
            .ignoresSafeArea()
    }
}

struct ModeButton: View {
    @Environment(\.dockScale) private var k
    let mode: Mode
    @ObservedObject var model: DockModel
    @ObservedObject var ticks: Ticks
    @State private var hover = false

    var body: some View {
        let active = model.state.current == mode.name
        let pending = model.pending == mode.name
        let ready = model.ready == mode.name && !active
        let tint = Color(hex: mode.color)
        // The wait shows as a ring for 10 s after a click, or while the pointer is on the button;
        // otherwise the button looks as it always does, the wait still running underneath.
        _ = ticks.second
        // An app asked for from the card in the wait's last minute opens with the mode: its icon
        // stands beside the countdown until then, whether you click or not.
        let held = pending ? model.heldApp : nil
        let ring = pending && (held != nil || hover || Date().timeIntervalSince(model.clickedAt) < 10)
        return Button { model.tap(mode.name) } label: {
            Group {
                if let held {
                    HStack(spacing: 5 * k) {
                        Image(nsImage: appIcon(held)).resizable().interpolation(.high).frame(width: 26 * k, height: 26 * k)
                        // The ring counts down the last minute, not the whole wait: it fills as the app comes.
                        Ring(progress: 1 - model.remaining / GateCore.holdWithin, tint: tint, label: short(model.remaining), dim: false)
                    }
                    .padding(.leading, 5 * k)
                    .background(Capsule().fill(tint.opacity(0.18)))
                    .transition(.blurReplace)
                } else if ring {
                    Ring(progress: progress, tint: tint, label: short(model.remaining), dim: false)
                        .transition(.blurReplace)
                } else {
                    HStack(spacing: 7 * k) {
                        Image(systemName: mode.icon).font(.system(size: 14 * k, weight: .semibold))
                        if active { Text(mode.name).font(.system(size: 14 * k, weight: .semibold)) }
                    }
                    .foregroundStyle(active ? Color.white : Color.primary.opacity(hover ? 0.9 : 0.55))
                    .padding(.horizontal, active ? 16 * k : 0)
                    .frame(minWidth: 36 * k, minHeight: 36 * k)
                    .background(Capsule().fill(active ? tint : Color.primary.opacity(hover ? 0.14 : 0.07)))
                    .transition(.blurReplace)
                }
            }
            .animation(.smooth(duration: 0.4), value: ring)
            .animation(.smooth(duration: 0.4), value: held)
            // Turned away: two red pulses, about a second in all.
            .keyframeAnimator(initialValue: 0.0, trigger: model.denied[mode.name] ?? 0) { v, t in
                v.background(Capsule().fill(Color(hex: "#E5484D").opacity(0.9 * t)))
                    .overlay {
                        if !ring {
                            Image(systemName: mode.icon).font(.system(size: 14 * k, weight: .semibold))
                                .foregroundStyle(.white).opacity(t)
                        }
                    }
                    .scaleEffect(1 + 0.06 * t)
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.12)
                CubicKeyframe(0.2, duration: 0.22)
                CubicKeyframe(1, duration: 0.16)
                CubicKeyframe(0, duration: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .overlay(Capsule().strokeBorder(Color.white.opacity(model.dropTarget == mode.name ? 0.9 : 0), lineWidth: 2 * k))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.modeFrames[mode.name] = g.frame(in: .named("dock")) }
                .onChange(of: g.frame(in: .named("dock"))) { _, f in model.modeFrames[mode.name] = f }
        })
        .onHover { hover = $0; model.hover(mode.name, $0) }
        .contextMenu {
            if pending { Button("Stop Waiting for \(mode.name)") { model.cancelGate() } }
            if ready { Button("Shut \(mode.name) Again") { model.ready = nil; model.saveGate() } }
        }
        .help(held.map { "\(CardIcon.name($0)) opens with \(mode.name) in \(long(model.remaining))" }
              ?? (pending ? "\(mode.name) in \(long(model.remaining)): click to cut the wait (it opens by itself only within 5 s of a click)"
              : (mode.gate == nil || active ? mode.name : "\(mode.name): free at the break, click to start the wait")))
    }

    var progress: Double { max(0, min(1, 1 - model.remaining / model.gateTotal)) }
}

/// An app's icon, looked up once: a drag redraws the card on every mouse move, a held app's
/// countdown every second.
@MainActor var appIcons: [String: NSImage] = [:]
@MainActor func appIcon(_ id: String) -> NSImage {
    if let i = appIcons[id] { return i }
    let i = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        ?? Apps.running(id).first?.icon
        ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    appIcons[id] = i
    return i
}

func short(_ t: Double) -> String {
    let s = Int(t.rounded(.up))
    return s >= 60 ? "\(Int((Double(s) / 60).rounded(.up)))m" : "\(s)s"
}

func long(_ t: Double) -> String {
    let s = Int(t.rounded(.up))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// A mode-sized circle: a ring that fills as the time runs, with the time left inside.
struct Ring: View {
    @Environment(\.dockScale) private var k
    let progress: Double
    let tint: Color
    let label: String
    let dim: Bool          // paused: the arc and the time stand still and fade, nothing else moves

    var body: some View {
        let p = max(0, min(1, progress))
        ZStack {
            Circle().fill(Color.primary.opacity(0.07))
            Circle().inset(by: 2 * k).stroke(Color.primary.opacity(0.12), lineWidth: 2.5 * k)
            Circle().inset(by: 2 * k).trim(from: 0, to: p)
                .stroke(tint.opacity(dim ? 0.4 : 1), style: StrokeStyle(lineWidth: 2.5 * k, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label).font(.system(size: 10.5 * k, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Color.primary.opacity(dim ? 0.5 : 0.85))
        }
        .frame(width: 36 * k, height: 36 * k)
        .animation(.smooth(duration: 0.4), value: dim)
    }
}

struct PreviewView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var card: CardState

    var body: some View {
        let mode = model.hovered ?? ""
        let drag = card.drag
        let ids = mode == pomoCard ? [] : drag?.ids ?? model.preview(mode)
        VStack(spacing: 6) {
            if mode == pomoCard {
                PomoPlanView(model: model, ticks: model.ticks)
            } else if ids.isEmpty {
                Text("No apps yet").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(height: 30)
            } else {
                HStack(spacing: CardDrag.stride - 36) {
                    ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                        let dragged = drag?.id == id
                        CardIcon(id: id, mode: mode, icon: icon(id), running: !Apps.running(id).isEmpty,
                                 dragged: dragged, model: model)
                            // The dragged icon stays under the mouse while its place in the row changes.
                            .offset(x: dragged ? CGFloat(drag!.from - i) * CardDrag.stride + drag!.dx : 0)
                            .zIndex(dragged ? 1 : 0)
                            // Its new place and offset land together, unanimated: an animated move
                            // under an offset that each mouse move set at once made it jump.
                            .transaction { if dragged { $0.animation = nil } }
                    }
                }
                .coordinateSpace(name: "card")
            }
            if mode != pomoCard {
                Text(mode).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .padding(mode == pomoCard ? 6 : 0)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            if mode == pomoCard { PopoverBlur().clipShape(shape) } else { shape.fill(.ultraThinMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .onHover { model.cardHover($0) }
        .padding(12)
        .fixedSize()
        // The card's real size, once SwiftUI has laid out what it now shows: the panel is sized and
        // centred from this, not from a measure taken before the new mode's apps were drawn.
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            model.previewSize = size
            model.onPreviewSize?()
        }
    }

    func icon(_ id: String) -> NSImage { appIcon(id) }
}

struct CardIcon: View {
    let id: String
    let mode: String
    let icon: NSImage
    let running: Bool
    let dragged: Bool
    @ObservedObject var model: DockModel
    @State private var hover = false

    static var names: [String: String] = [:]
    static func name(_ id: String) -> String {
        if let n = names[id] { return n }
        let n = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id
        names[id] = n
        return n
    }

    /// One gesture for both: a press that moves 4 pt drags the icon along the card, one that
    /// does not opens the app.
    var body: some View {
        Image(nsImage: icon).resizable().interpolation(.high)
            .frame(width: 30, height: 30)
            .opacity(running ? 1 : 0.45)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hover || dragged ? 0.14 : 0)))
            .scaleEffect(dragged ? 1.12 : 1)
            .shadow(color: .black.opacity(dragged ? 0.3 : 0), radius: 4, y: 2)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("card"))
                .onChanged { v in model.cardDragChanged(mode, id, v.translation) }
                .onEnded { _ in if !model.cardDragEnded(mode) { model.openFromCard(mode, id) } })
            .help(Self.name(id) + ": click to open, drag to reorder")
            .contextMenu {
                Button("Remove from \(mode)'s Top 5") { model.setOnCard(id, mode, false) }
            }
    }
}

/// The dock never takes focus, and SwiftUI's material fades in a window without it, which left the
/// plan's text unreadable over a light page: this is the popover's own blur, kept active.
struct PopoverBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The day's plan: a row of capsules for each set, as wide as they are long. What has passed is
/// filled, the block running fills as it runs, and what is ahead is a plain track.
struct PomoPlanView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var ticks: Ticks
    static let focusTint = Color(hex: "#E8663D")   // the pomodoro ring's two colours
    static let breakTint = Color(hex: "#34A853")

    var body: some View {
        _ = ticks.second
        let plan = model.plan
        let done = model.pomoBlock >= plan.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(plan)).font(.system(size: 13, weight: .semibold))
                    Text(subtitle(done)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if !done {
                    Text(long(model.pomoLeft))
                        .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(model.state.pomoPhase != nil && model.pomoRunning ? .primary : .secondary)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: Int(model.pomoLeft))
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(stride(from: 0, to: plan.count, by: 8)), id: \.self) { start in
                    row(plan, start)
                }
            }
            HStack(spacing: 12) {
                legend(Self.focusTint, "\(Int(plan[0].minutes)) min rounds")
                legend(Self.breakTint, "\(Int(plan[1].minutes)) min breaks")
            }
        }
        .frame(width: 444)
    }

    func row(_ plan: [PomoBlock], _ start: Int) -> some View {
        // The set that ends in lunch is the longest: it sets the scale.
        let perMinute = 350 / plan[8..<16].reduce(0) { $0 + $1.minutes }
        let end = plan[start + 7]
        return HStack(spacing: 3) {
            ForEach(start..<(start + 8), id: \.self) { i in
                segment(plan, i, width: (plan[i].minutes * perMinute).rounded())
            }
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                if end.kind == .lunch { Image(systemName: "fork.knife") }
                Text("\(Int(end.minutes)) min")
            }
            .font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            .fixedSize()
        }
    }

    func segment(_ plan: [PomoBlock], _ i: Int, width: CGFloat) -> some View {
        let at = model.pomoBlock
        let active = i == at && model.state.pomoPhase != nil
        // Clamped: a round shortened in the config can have more time left than its new length.
        let filled = i < at ? 1 : active ? max(0, min(1, 1 - model.pomoLeft / model.pomoLength)) : 0
        let tint = plan[i].kind == .focus ? Self.focusTint : Self.breakTint
        return Capsule().fill(Color.primary.opacity(active ? 0.22 : 0.13))
            .overlay(alignment: .leading) {
                tint.opacity(active && !model.pomoRunning ? 0.5 : 1).frame(width: width * filled)
            }
            .clipShape(Capsule())
            .frame(width: width, height: active ? 10 : 7)
            .frame(height: 10)
    }

    func legend(_ tint: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    func title(_ plan: [PomoBlock]) -> String {
        let at = model.pomoBlock
        guard at < plan.count else { return "Day complete" }
        if model.state.pomoPhase != nil, plan[at].kind != .focus { return plan[at].kind == .lunch ? "Lunch" : "Break" }
        let rounds = plan.filter { $0.kind == .focus }.count
        return "Round \(plan[..<at].filter { $0.kind == .focus }.count + 1) of \(rounds)"
    }

    func subtitle(_ done: Bool) -> String {
        let count = "\(model.pomoCount) finished today"
        if done { return "\(count) · click the timer to start over" }
        if model.state.pomoPhase == nil { return "\(count) · click the timer to start" }
        return model.pomoRunning ? count : "Paused · \(count)"
    }
}

/// Two rings that spread out from the pomodoro and fade, with a short glow: "a focus round is on".
struct Halo: View {
    @Environment(\.dockScale) private var k
    let trigger: Int
    let tint: Color
    @State private var spread = true   // at rest: spread out and invisible

    var body: some View {
        ZStack {
            Circle().strokeBorder(tint, lineWidth: 2.5 * k)
                .scaleEffect(spread ? 1.4 : 1).opacity(spread ? 0 : 1)
                .shadow(color: tint.opacity(spread ? 0 : 0.8), radius: 6 * k)
            Circle().strokeBorder(tint.opacity(0.55), lineWidth: 1.5 * k)
                .scaleEffect(spread ? 1.6 : 1.08).opacity(spread ? 0 : 0.7)
        }
        .frame(width: 36 * k, height: 36 * k)
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { spread = false }
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.75)) { spread = true }
            }
        }
    }
}

struct PomodoroView: View {
    @Environment(\.dockScale) private var k
    @ObservedObject var model: DockModel
    @ObservedObject var ticks: Ticks
    @State private var hover = false

    var body: some View {
        _ = ticks.second
        let onBreak = model.state.pomoPhase == "break"
        let idle = model.state.pomoPhase == nil
        let paused = !idle && !model.pomoRunning
        let tint = onBreak ? Color(hex: "#34A853") : Color(hex: "#E8663D")
        let progress = idle ? 0 : 1 - model.pomoLeft / model.pomoLength
        return Button { model.pomoTap() } label: {
            ZStack {
                if idle {
                    Circle().fill(Color.primary.opacity(hover ? 0.14 : 0.07)).frame(width: 36 * k, height: 36 * k)
                    Image(systemName: "timer").font(.system(size: 14 * k, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(hover ? 0.9 : 0.55))
                } else {
                    Ring(progress: progress, tint: tint, label: short(model.pomoLeft), dim: paused)
                        .keyframeAnimator(initialValue: 1.0, trigger: model.nudge) { ring, t in ring.scaleEffect(t) } keyframes: { _ in
                            SpringKeyframe(1.12, duration: 0.15)
                            SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
                        }
                        // Pausing and resuming: the ring dips as if pressed, then springs back.
                        .keyframeAnimator(initialValue: 1.0, trigger: paused) { ring, t in ring.scaleEffect(t) } keyframes: { _ in
                            SpringKeyframe(0.86, duration: 0.12)
                            SpringKeyframe(1.0, duration: 0.45, spring: .bouncy)
                        }
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay(Halo(trigger: model.nudge, tint: tint))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.pomoFrame = g.frame(in: .named("dock")) }
                .onChange(of: g.frame(in: .named("dock"))) { _, f in model.pomoFrame = f }
        })
        .onHover { hover = $0; model.hover(pomoCard, $0) }
        .contextMenu {
            Button(idle ? "Start Focus" : (paused ? "Resume" : "Pause")) { model.pomoTap() }
            if !idle { Button(skipTitle) { model.pomoSkip() } }
            Button("Reset") { model.pomoReset() }
            if model.pomoBlock > 0 {
                Button("Start the Day Over") { model.state.pomoBlock = 0; model.pomoReset() }
            }
        }
    }

    var skipTitle: String {
        let next = model.pomoBlock + 1
        guard next < model.plan.count else { return "Finish the Day" }
        switch model.plan[next].kind {
        case .focus: return "Skip to Focus"
        case .rest: return "Skip to Break"
        case .lunch: return "Skip to Lunch"
        }
    }
}

struct AppIcon: View {
    @Environment(\.dockScale) private var k
    let app: NSRunningApplication
    @ObservedObject var model: DockModel
    @State private var hover = false

    var body: some View {
        let id = app.bundleIdentifier ?? ""
        Button { if !model.justDragged { model.bringUp(id, app) } } label: {
            VStack(spacing: 3 * k) {
                Image(nsImage: app.icon ?? NSImage())
                    .resizable().interpolation(.high)
                    .frame(width: 38 * k, height: 38 * k)
                    .scaleEffect(hover ? 1.1 : 1, anchor: .bottom)
                Circle().fill(Color.primary.opacity(model.frontmost == id ? 0.85 : 0.35))
                    .frame(width: 4 * k, height: 4 * k)
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain)
        .opacity(model.draggedApp?.processIdentifier == app.processIdentifier ? 0.3 : 1)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.appFrames[app.processIdentifier] = g.frame(in: .named("dock")) }
                .onChange(of: g.frame(in: .named("dock"))) { _, f in model.appFrames[app.processIdentifier] = f }
                .onDisappear { model.appFrames[app.processIdentifier] = nil }
        })
        .onHover { hover = $0 }
        .help("\(app.localizedName ?? id): drag onto a mode to move it there")
        .contextMenu {
            if model.active(\.rectangle) {
                Menu("Rectangle") {
                    ForEach(Apps.layouts, id: \.1) { title, action in
                        Button(title) { Apps.place(id, action) }
                    }
                }
                Divider()
            }
            let shared = model.isShared(id)
            let targets = id == finderID ? [] : model.config.modes.map(\.name).filter { shared || $0 != model.state.current }
            ForEach(targets, id: \.self) { mode in
                Button("Move to \(mode)") { model.moveApp(app, to: mode) }
            }
            if !shared { Button("Show in All Modes") { model.share(app) } }
            if let mode = shared ? model.state.current : model.owner(id), !model.preview(mode).contains(id) {
                Button("Add to \(mode)'s Top 5") { model.setOnCard(id, mode, true) }
            }
            Button("Quit \(app.localizedName ?? "App")") { app.terminate() }
        }
    }
}

final class ClickThroughHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - App

/// Fits made per window, so one that keeps coming back is left alone. Touched on `axQueue` only.
final class Fits: @unchecked Sendable {
    var counts: [CFHashCode: Int] = [:]

    /// `from`, after a resize: the old limit. A window that ended there ends at the new one, taller
    /// or shorter, and every window may be fitted three times again.
    func run(_ pid: pid_t, _ id: String, limit: CGFloat, span: ClosedRange<CGFloat>, highest: CGFloat, from: CGFloat? = nil,
             screenX: ClosedRange<CGFloat> = -.infinity ... .infinity) {
        if let from {
            counts = [:]
            for w in AX.windows(pid) {
                guard AX.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole, AX.bool(w, "AXFullScreen") != true,
                      AX.bool(w, kAXMinimizedAttribute) != true, let p = AX.point(w), let sz = AX.size(w),
                      abs(p.y + sz.height - from) < 1.5, limit - p.y >= 200,
                      screenX.contains(p.x + sz.width / 2) else { continue }   // on the dock's screen
                if AX.setSize(w, CGSize(width: sz.width, height: limit - p.y)) { log("fit \(id) window to the resized dock") }
            }
        }
        for w in AX.windows(pid) {
            guard (counts[CFHash(w)] ?? 0) < 3, AX.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                  AX.bool(w, "AXFullScreen") != true, AX.bool(w, kAXMinimizedAttribute) != true,
                  let p = AX.point(w), let sz = AX.size(w),
                  p.y + sz.height > limit + 0.5, p.y < limit,
                  p.x < span.upperBound, p.x + sz.width > span.lowerBound else { continue }
            let tall = limit - p.y >= 200 && AX.setSize(w, CGSize(width: sz.width, height: limit - p.y))
            if !tall || (AX.size(w).map { p.y + $0.height > limit + 0.5 } ?? false) {
                _ = AX.setPoint(w, CGPoint(x: p.x, y: max(highest, limit - (AX.size(w)?.height ?? sz.height))))
            }
            let fitted = AX.point(w).flatMap { q in AX.size(w).map { q.y + $0.height <= limit + 0.5 } } ?? false
            counts[CFHash(w), default: 0] += fitted ? 1 : 3
            log("fit \(id) window above the dock: \(fitted ? "done" : "refused, left alone")")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var hotKeys: ModeHotKeys?
    var modeServer: ModeServer?
    var raycastSync: RaycastSync?
    var panel: NSPanel!
    var host: NSView!
    var model: DockModel!
    var previewPanel: NSPanel!
    var previewHost: NSView!
    var dragPanel: NSPanel!
    let dragIcon = NSImageView()
    var left: Double?          // the dock keeps its left edge, so buttons never move under the cursor

    func makePanel(_ view: NSView, mouse: Bool) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.ignoresMouseEvents = !mouse
        // The dock is never the active app (its panels do not activate it), and macOS shows a
        // window's tooltips only while its app is active unless the window allows them: without
        // this, a `.help` in the dock or its card hardly ever showed.
        p.allowsToolTipsWhenApplicationIsInactive = mouse
        // Not .fullScreenAuxiliary: macOS keeps the dock out of a full-screen space by itself.
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = view
        return p
    }

    /// Keeps macOS from napping or throttling the dock as a background app when the machine is busy.
    var activity: NSObjectProtocol?

    var switcher: SwitcherController!

    func applicationWillTerminate(_ note: Notification) { nativeCommandTab(true) }

    func applicationDidFinishLaunching(_ note: Notification) {
        restoreCommandTabOnExit()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "The dock answers clicks at once")
        if !Vis.trusted { Vis.askForAccessibility() }
        model = DockModel()
        let dockHost = ClickThroughHostingView(rootView: ScaledDock(model: model))
        // The hosting view would size the window to the unscaled dock, keeping its top edge, which
        // left a strip under it and a gap at its end; the panel's size is `place`'s alone.
        dockHost.sizingOptions = []
        host = dockHost
        panel = makePanel(host, mouse: true)
        panel.setContentSize(NSSize(width: 600, height: 90))   // room for the first layout
        let cardHost = ClickThroughHostingView(rootView: PreviewView(model: model, card: model.card))
        cardHost.sizingOptions = []   // left to size the panel, it kept the left edge and the card slid
        previewHost = cardHost
        model.onPreviewSize = { [weak self] in self?.placePreview() }
        previewPanel = makePanel(previewHost, mouse: true)
        left = model.state.dockLeft
        model.onChange = { [weak self] in self?.place() }
        model.onHover = { [weak self] mode in self?.showPreview(mode) }
        dragIcon.imageScaling = .scaleProportionallyUpOrDown
        dragIcon.shadow = { let s = NSShadow(); s.shadowBlurRadius = 6; s.shadowOffset = NSSize(width: 0, height: -3)
            s.shadowColor = NSColor.black.withAlphaComponent(0.35); return s }()
        dragPanel = makePanel(dragIcon, mouse: false)
        dragPanel.level = .popUpMenu   // above the dock and its card
        model.onAppDrag = { [weak self] icon in self?.showDragIcon(icon) }
        model.frame = { [weak self] in self?.panel.frame ?? .zero }
        model.layoutNow = { [weak self] in self?.place() }
        model.recenter = { [weak self] in
            self?.left = nil
            self?.place()
        }
        model.position = { [weak self] in Double(self?.panel.frame.minX ?? 0) }
        switcher = SwitcherController(model: model)
        hotKeys = ModeHotKeys(model: model)
        modeServer = ModeServer(model: model)
        raycastSync = RaycastSync(model: model)
        model.onAddIns = { [weak self] in self?.applyAddIns() }
        applyAddIns()
        switcher.prewarm()
        model.move = { [weak self] x in
            self?.left = x.rounded()
            self?.place()
        }
        // One line to read after a macOS update: what the dock leans on, and whether it is there.
        let v = ProcessInfo.processInfo.operatingSystemVersion
        log("start on macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion): Accessibility \(Vis.trusted ? "granted" : "NOT granted (hiding falls back to System Events)"), Cmd-Tab call \(canTurnOffNativeCommandTab ? "found" : "missing (macOS's switcher stays)"), WindowServer focus \(WindowServer.available ? "found" : "missing (focus asks macOS)")")
        every(0.5) { [weak self] in
            guard let self else { return }
            beats += 1
            place()   // a backstop, cheap when unchanged
            // Each lists the windows or asks the front app over Accessibility. A change of Space or of
            // front app is followed at once below, so this only catches the rest: every 2 s, idle 8 s.
            if beats % (idleSeconds < 5 ? 4 : 16) == 0 { followFullScreen(); fitWindows() }
        }
        place()
        panel.orderFrontRegardless()
        followFullScreen()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followFullScreen() }
                // Leaving full screen changes the Space, and the dock comes back on the second look
                // that finds none: take it soon after rather than at the next poll.
                guard name == NSWorkspace.activeSpaceDidChangeNotification else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { MainActor.assumeIsolated { self?.followFullScreen() } }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.model.state.dockLeft == nil { self?.left = nil }
                self?.place()
            }
        }
    }

    /// Size the panel to the dock's laid-out size, standing on the lower edge of the
    /// main screen, its left edge where it was (centred the first time), never off the screen.
    /// Cheap when nothing changed, so the 0.5 s timer also calls it as a backstop.
    func place() {
        guard let screen else { return }
        let natural = model.natural
        guard natural.width >= 1, natural.height >= 1 else { return }   // not laid out yet: the timer retries
        let size = NSSize(width: natural.width.rounded(), height: natural.height.rounded())   // drawn at its size already
        let sf = screen.frame
        if left == nil { left = model.state.dockLeft ?? (sf.midX - size.width / 2).rounded() }
        let x = min(max(left!, sf.minX), sf.maxX - size.width)
        let target = NSRect(x: x, y: sf.minY, width: size.width, height: size.height)
        if panel.frame != target { panel.setFrame(target, display: true) }
        if !model.dragging { syncRectangleGap(); fitAfterResize() }
    }

    /// After a resize, fit the front window to the dock's new top at once rather than at the next
    /// two-second check. The drag's end can come while the button still reads as down: retried.
    var fittedTop: CGFloat = -1
    func fitAfterResize() {
        guard barTop != fittedTop, !model.dragging else { return }
        if fitting || NSEvent.pressedMouseButtons != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { MainActor.assumeIsolated { self.fitAfterResize() } }
            return
        }
        let old = fittedTop
        fittedTop = barTop
        fitWindows(from: old < 0 ? nil : old)
    }

    /// Each add-in on or off as the config has it; called at start, on a reload and from the menu.
    func applyAddIns() {
        switcher?.apply(model.addIn(\.switcher))
        hotKeys?.setEnabled(model.addIn(\.optionKeys))
        modeServer?.setEnabled(AddIns.browsers.contains { model.active($0.key) })
        raycastSync?.setEnabled(model.active(\.raycast))
        if model.active(\.rectangle) { syncRectangleGap() } else { restoreRectangleGap() }
    }

    /// The screen with the menu bar: the dock stays there rather than following focus between displays.
    var screen: NSScreen? { NSScreen.screens.first }
    /// The top of the dock's visible body, from its size alone: the panel's frame lags a resize
    /// and changed with what the row held, and Rectangle is restarted for every new gap.
    var barTop: CGFloat { (screen?.frame.minY ?? panel.frame.minY) + DockView.bodyTop * model.scale }
    let margin: CGFloat = 0   // windows end right on the dock's top edge
    var restartingRectangle = false
    let fits = Fits()
    var fitting = false
    var beats = 0
    var hiddenForFullScreen = false

    var fullChecking = false
    var fullMisses = 0

    /// The dock steps aside while the front app is full screen. macOS says so of its window
    /// (AXFullScreen), asked on the Accessibility queue; a video or game that covers the screen in
    /// its own way is caught by its window's frame. On a screen with a notch a full-screen window
    /// starts below the notch, so its frame alone matched only mid-animation and the dock came
    /// straight back (3 November 2026). It returns after two reads in a row find no full screen.
    func followFullScreen() {
        guard !fullChecking, let app = NSWorkspace.shared.frontmostApplication,
              app != NSRunningApplication.current, let s = screen else { return }
        let pid = app.processIdentifier
        let covers = frontCovers(pid, s)
        guard Vis.trusted, !covers else { applyFullScreen(covers); return }
        fullChecking = true
        axQueue.async {
            let full = AX.fullScreen(pid)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.fullChecking = false
                    // Asked about an app that has since left the front: ask about the one there now.
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { self?.followFullScreen(); return }
                    self?.applyFullScreen(full)
                }
            }
        }
    }

    func applyFullScreen(_ full: Bool) {
        fullMisses = full ? 0 : fullMisses + 1
        guard full != hiddenForFullScreen, full || fullMisses >= 2 else { return }
        hiddenForFullScreen = full
        if full {
            model.closeCard()
            previewPanel.orderOut(nil)
            panel.orderOut(nil)
        } else {
            place()
            panel.orderFrontRegardless()
        }
        log("full screen: dock \(full ? "hidden" : "shown")")
    }

    /// A window of the app that covers the whole screen, or all of it below the notch.
    func frontCovers(_ pid: pid_t, _ screen: NSScreen) -> Bool {
        let size = screen.frame.size, notch = screen.safeAreaInsets.top
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        // Window bounds are global, from the top left of the main screen, the one the dock is on.
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double] else { return false }
            let y = b["Y"] ?? -1, bottom = y + (b["Height"] ?? 0)
            return abs(b["X"] ?? 1) < 1 && abs((b["Width"] ?? 0) - size.width) < 1
                && (abs(y) < 1 || (notch > 0 && abs(y - notch) < 1)) && abs(bottom - size.height) < 1
        }
    }

    /// Rectangle leaves the dock's height free at the bottom edge, so its layouts stop above the
    /// dock. It reads the gap only at launch, so a new gap restarts it, at once: the gap comes from
    /// the dock's size alone, never from a size it passes through, and a resize sets it when the
    /// drag ends. A restart takes about 0.2 s (quit 50 ms, open 135 ms, 8 November); a gap that
    /// changes during one is written and restarts it once more when it is up.
    func syncRectangleGap() {
        guard model.active(\.rectangle), !restartingRectangle, let vf = screen?.visibleFrame else { return }
        let gap = max(0, (barTop - vf.minY + margin).rounded(.up))
        let domain = "com.knollsoft.Rectangle" as CFString
        func pref(_ key: String) -> CFPropertyList? { CFPreferencesCopyAppValue(key as CFString, domain) }
        let now = (pref("screenEdgeGapBottom") as? NSNumber)?.doubleValue
        // The dock is on the main screen only, so the gap is too: Rectangle's main-screen-only
        // switch, unless you gave other edges a gap of your own, which it would take off the
        // other screens as well.
        let ownGaps = ["screenEdgeGapTop", "screenEdgeGapLeft", "screenEdgeGapRight"].contains { ((pref($0) as? NSNumber)?.doubleValue ?? 0) != 0 }
        let mainOnly = (pref("screenEdgeGapsOnMainScreenOnly") as? NSNumber)?.boolValue ?? false
        let setMainOnly = !mainOnly && !ownGaps
        guard now.map({ abs($0 - gap) >= 1 }) ?? true || setMainOnly else { return }
        if model.state.rectangleOwn == nil {
            model.state.rectangleOwn = RectangleOwn(gap: now, mainOnly: (pref("screenEdgeGapsOnMainScreenOnly") as? NSNumber)?.boolValue)
            writeJSON(stateURL, model.state)
        }
        CFPreferencesSetAppValue("screenEdgeGapBottom" as CFString, NSNumber(value: Float(gap)), domain)
        if setMainOnly { CFPreferencesSetAppValue("screenEdgeGapsOnMainScreenOnly" as CFString, kCFBooleanTrue, domain) }
        CFPreferencesAppSynchronize(domain)
        log("Rectangle bottom gap \(now.map { String($0) } ?? "unset") -> \(gap)\(setMainOnly ? ", on the main screen only" : "")")
        restartRectangle()
    }

    /// The add-in switched off: Rectangle gets back the gap it had before the dock set one. A gap
    /// set by a dock from before this record is known by matching the dock's own, and is unset.
    func restoreRectangleGap() {
        guard !restartingRectangle, let vf = screen?.visibleFrame else { return }
        let domain = "com.knollsoft.Rectangle" as CFString
        let now = (CFPreferencesCopyAppValue("screenEdgeGapBottom" as CFString, domain) as? NSNumber)?.doubleValue
        let own: RectangleOwn
        if let o = model.state.rectangleOwn {
            own = o
        } else if let now, abs(now - max(0, (barTop - vf.minY + margin).rounded(.up))) < 1 {
            own = RectangleOwn(gap: nil, mainOnly: nil)
        } else {
            return
        }
        func set(_ key: String, _ v: CFPropertyList?) { CFPreferencesSetAppValue(key as CFString, v, domain) }
        set("screenEdgeGapBottom", own.gap.map { NSNumber(value: Float($0)) })
        set("screenEdgeGapsOnMainScreenOnly", own.mainOnly.map { $0 ? kCFBooleanTrue : kCFBooleanFalse })
        CFPreferencesAppSynchronize(domain)
        model.state.rectangleOwn = nil
        writeJSON(stateURL, model.state)
        log("Rectangle bottom gap \(now.map { String($0) } ?? "unset") -> \(own.gap.map { String($0) } ?? "unset"), its own again")
        restartRectangle()
    }

    /// Rectangle reads its gaps only at launch.
    func restartRectangle() {
        guard let r = NSRunningApplication.runningApplications(withBundleIdentifier: "com.knollsoft.Rectangle").first,
              let url = r.bundleURL else { return }
        restartingRectangle = true
        r.terminate()
        Task { @MainActor in   // reopen only once it has gone, or the open is lost on the old one
            for _ in 0..<500 where !r.isTerminated { try? await Task.sleep(for: .milliseconds(10)) }
            let c = NSWorkspace.OpenConfiguration()
            c.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: c)
            restartingRectangle = false
            syncRectangleGap()   // the size changed again meanwhile: once more
        }
    }

    /// Windows stay above the dock: twice a second, a standard window of the front app that reaches
    /// into the dock's band is shortened (or, when short or fixed in size, lifted) to end `margin`
    /// above it. Never while a mouse button is down, so a window being dragged is left to the user.
    func fitWindows(from oldTop: CGFloat? = nil) {
        let inset = 14 * model.scale
        guard !fitting, !hiddenForFullScreen, Vis.trusted, NSEvent.pressedMouseButtons == 0, !model.dragging, panel.frame.width > 2 * inset + 1,
              let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current,
              let top = NSScreen.screens.first?.frame.maxY else { return }
        let limit = top - barTop - margin          // Accessibility measures y down from the top
        let span = CGFloat(panel.frame.minX + inset)...CGFloat(panel.frame.maxX - inset)
        let highest = top - (screen?.visibleFrame.maxY ?? top)
        let screenX = (screen?.frame.minX ?? 0)...(screen?.frame.maxX ?? 0)
        let pid = app.processIdentifier, id = app.bundleIdentifier ?? "?", fits = self.fits
        fitting = true   // one pass at a time: a slow app makes the timer skip, not pile up
        axQueue.async {
            fits.run(pid, id, limit: limit, span: span, highest: highest, from: oldTop.map { top - $0 - self.margin }, screenX: screenX)
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.fitting = false } }
        }
    }

    /// The dragged app's icon under the mouse, anywhere on the screen.
    func showDragIcon(_ icon: NSImage?) {
        guard let icon else { dragPanel.orderOut(nil); return }
        if dragIcon.image !== icon { dragIcon.image = icon }
        let side = (44 * model.scale).rounded(), m = NSEvent.mouseLocation
        dragPanel.setFrame(NSRect(x: (m.x - side / 2).rounded(), y: (m.y - side / 2).rounded(), width: side, height: side + 6),
                           display: true)
        if !dragPanel.isVisible { dragPanel.orderFrontRegardless() }
    }

    var previewMode: String?

    /// The card fades in once and then stays put: moving to another mode's button moves it there,
    /// and a fade-out that a new hover overtook does not take the card away.
    func showPreview(_ mode: String?) {
        guard let mode, model.cardFrame(mode) != nil, !hiddenForFullScreen else {
            previewMode = nil
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.12
                previewPanel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { if self.previewMode == nil { self.previewPanel.orderOut(nil) } }
            })
            return
        }
        let appearing = previewMode == nil || !previewPanel.isVisible
        previewMode = mode
        placePreview()
        if appearing {
            previewPanel.alphaValue = 0
            previewPanel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = appearing ? 0.15 : 0.08
            previewPanel.animator().alphaValue = 1
        }
    }

    /// Centred over the mode's button or the pomodoro, just above the dock, in whole points.
    func placePreview() {
        guard let mode = previewMode, let f = model.cardFrame(mode) else { return }
        let size = model.previewSize == .zero ? previewHost.fittingSize : model.previewSize
        guard size.width >= 1 else { return }
        // The button's frame is in the dock view's flipped coordinates.
        let cx = panel.frame.minX + f.midX
        let top = panel.frame.maxY - f.minY
        let sf = screen?.frame ?? panel.frame
        let x = min(max((cx - size.width / 2).rounded(), sf.minX), sf.maxX - size.width)
        let target = NSRect(x: x, y: (top - 6).rounded(), width: size.width.rounded(), height: size.height.rounded())
        if previewPanel.frame != target { previewPanel.setFrame(target, display: true) }
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
