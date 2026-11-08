import Foundation

/// The rules of a gated mode's wait (Socials), as plain values so tests/gate-tests.swift can try
/// every case without a dock. DockModel keeps the state and does what these decide.
enum GateCore {
    static let cutPerClick = 0.15        // share of the remaining wait each further click removes
    static let floorSeconds = 3.0        // clicking never brings the wait below this
    static let clickPause: TimeInterval = 5   // a pause this long ends a burst of clicks
    static let warnings = 3              // clicks that only warn, at the start of each burst in focus
    static let holdWithin: TimeInterval = 60  // an app asked for with less wait than this opens when it runs out

    /// What the dock knows when a mode's button is clicked.
    struct Tap {
        var name: String
        var current: String
        var gated: Bool                  // the mode clicked has a gate
        var unblocked: Bool              // on a break, or the timer paused
        var focus: Bool                  // the pomodoro's phase is focus (running or not)
        var ready: String?
        var leftGated: (mode: String, at: Date)?
        var pending: String?
        var deadline: Date?
        var nudges: Int
        var nudgedAt: Date
        var now: Date
    }

    enum Outcome: Equatable {
        case stay                        // the mode is the current one
        case open                        // switch now
        case back                        // switch now: the gated mode was left a moment ago
        case nudge(Int)                  // a warning, the nth of the burst
        case cut(Double)                 // the wait goes on, this many seconds from now
        case start                       // a wait starts (and a focus round, if none is set)
    }

    static func tap(_ t: Tap) -> Outcome {
        if t.name == t.current { return .stay }
        if t.ready == t.name { return .open }
        if backWithin(t.leftGated, t.name, t.now) { return .back }
        guard t.gated, !t.unblocked else { return .open }
        if t.focus {
            let n = t.now.timeIntervalSince(t.nudgedAt) > clickPause ? 0 : t.nudges
            if n < warnings { return .nudge(n + 1) }
        }
        if t.pending == t.name, let d = t.deadline { return .cut(cut(max(0, d.timeIntervalSince(t.now)))) }
        return .start
    }

    /// The wait left after one more click.
    static func cut(_ remaining: Double) -> Double {
        min(remaining, max(floorSeconds, remaining * (1 - cutPerClick)))
    }

    /// Left the gated mode `name` so recently that going back needs no wait.
    static func backWithin(_ left: (mode: String, at: Date)?, _ name: String, _ now: Date) -> Bool {
        guard let left, left.mode == name else { return false }
        return now.timeIntervalSince(left.at) <= clickPause
    }

    /// An app asked for from the mode's card holds the wait open when under a minute was left at the last click.
    static func holdsApp(launchFor: String?, pending: String?, deadline: Date, clickedAt: Date) -> Bool {
        launchFor != nil && launchFor == pending && deadline.timeIntervalSince(clickedAt) < holdWithin
    }

    /// Clicking stopped: a wait cut short goes back to the round's end, unless an app holds it.
    static func resets(deadline: Date, roundEnd: Date?, focusRunning: Bool, clickedAt: Date, holds: Bool, now: Date) -> Bool {
        guard focusRunning, let roundEnd, roundEnd.timeIntervalSince(deadline) > 1 else { return false }
        return now.timeIntervalSince(clickedAt) > clickPause && !holds
    }

    /// When a wait runs out, it opens the mode only for someone still asking: a click in the last
    /// pause, or an app held.
    static func asking(clickedAt: Date, holds: Bool, now: Date) -> Bool {
        now.timeIntervalSince(clickedAt) <= clickPause || holds
    }

    /// An app of a gated mode brought forward some other way (Cmd-Tab, Raycast, a notification):
    /// it may take the dock there when a click on the mode would open it at once.
    static func followAllowed(mode: String, unblocked: Bool, ready: String?, leftGated: (mode: String, at: Date)?, now: Date) -> Bool {
        unblocked || ready == mode || backWithin(leftGated, mode, now)
    }
}
