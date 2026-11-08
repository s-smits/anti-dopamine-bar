import Foundation

// Tests of a gated mode's wait (gatecore.swift), built alone by tests/run.sh: the rules for Socials
// during a focus round, a break and a pause, with the clock as a plain value.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passes += 1 } else { failures += 1; print("FAIL \(what) (line \(line))") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) {
    check(a == b, "\(what): got \(a), want \(b)", line: line)
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

/// A click on Socials from Profile 1 during a running focus round, nothing else going on.
func socials(_ change: (inout GateCore.Tap) -> Void = { _ in }) -> GateCore.Outcome {
    var t = GateCore.Tap(name: "Socials", current: "Profile 1", gated: true, unblocked: false, focus: true,
                         ready: nil, leftGated: nil, pending: nil, deadline: nil, nudges: 0,
                         nudgedAt: .distantPast, now: t0)
    change(&t)
    return GateCore.tap(t)
}

// MARK: - Clicking

func testTap() {
    eq(socials { $0.current = "Socials" }, .stay, "a click on the mode you are in")
    eq(socials { $0.gated = false; $0.name = "Profile 2" }, .open, "a mode without a gate")
    eq(socials { $0.unblocked = true }, .open, "a break or a pause opens it at once")
    eq(socials { $0.unblocked = true; $0.pending = "Socials"; $0.deadline = at(600) }, .open,
       "a break opens it even with a wait running")
    eq(socials { $0.ready = "Socials" }, .open, "a wait that ran out: the next click opens it")

    // Three warnings a burst, during focus only.
    eq(socials(), .nudge(1), "the first click warns")
    eq(socials { $0.nudges = 1; $0.nudgedAt = at(-1) }, .nudge(2), "the second click warns")
    eq(socials { $0.nudges = 2; $0.nudgedAt = at(-1) }, .nudge(3), "the third click warns")
    eq(socials { $0.nudges = 3; $0.nudgedAt = at(-1) }, .start, "the fourth click starts the wait")
    eq(socials { $0.nudges = 3; $0.nudgedAt = at(-5) }, .start, "5 s on, still the same burst")
    eq(socials { $0.nudges = 3; $0.nudgedAt = at(-5.1) }, .nudge(1), "over 5 s without a click: the warnings are back")
    eq(socials { $0.focus = false }, .start, "the timer stopped: the first click starts a round and the wait, no warning")

    // Cutting.
    eq(socials { $0.nudges = 3; $0.nudgedAt = at(-1); $0.pending = "Socials"; $0.deadline = at(1000) }, .cut(800),
       "a click cuts 20% of the wait left")
    eq(socials { $0.nudges = 3; $0.nudgedAt = at(-1); $0.pending = "Socials"; $0.deadline = at(-2) }, .cut(0),
       "a wait already over is not lengthened")
    eq(socials { $0.nudges = 0; $0.nudgedAt = at(-30); $0.pending = "Socials"; $0.deadline = at(1000) }, .nudge(1),
       "coming back to a running wait after a pause warns first")
    eq(socials { $0.nudges = 3; $0.nudgedAt = at(-1); $0.pending = "Profile 2"; $0.deadline = at(1000) }, .start,
       "a wait for another mode does not count")
}

func testCut() {
    eq(GateCore.cut(1000), 800, "20% off")
    eq(GateCore.cut(3.5), 3, "never below 3 s")
    eq(GateCore.cut(3), 3, "at the floor it stays")
    eq(GateCore.cut(2), 2, "under the floor it is not raised")
    eq(GateCore.cut(0), 0, "nothing left stays nothing")
    // From a full round, clicking alone gets in after about 30 clicks, not a few and not a hundred.
    var left = 25 * 60.0, clicks = 0
    while left > GateCore.floorSeconds && clicks < 500 { left = GateCore.cut(left); clicks += 1 }
    check((25...35).contains(clicks), "25 minutes take 25 to 35 clicks to reach the floor, took \(clicks)")
}

// MARK: - Going back

func testBack() {
    let left = (mode: "Socials", at: t0)
    eq(socials { $0.leftGated = left; $0.now = at(4.9) }, .back, "back within 5 s: no wait, no warning")
    eq(socials { $0.leftGated = left; $0.now = at(5) }, .back, "at 5 s still")
    eq(socials { $0.leftGated = left; $0.now = at(5.1) }, .nudge(1), "after 5 s the warnings and the wait again")
    eq(socials { $0.leftGated = (mode: "Other", at: t0); $0.now = at(1) }, .nudge(1), "leaving another mode does not count")
    check(GateCore.followAllowed(mode: "Socials", unblocked: false, ready: nil, leftGated: left, now: at(3)),
          "Cmd-Tab back to a Socials app within 5 s follows it")
    check(!GateCore.followAllowed(mode: "Socials", unblocked: false, ready: nil, leftGated: left, now: at(6)),
          "Cmd-Tab to a Socials app later is blocked")
    check(GateCore.followAllowed(mode: "Socials", unblocked: true, ready: nil, leftGated: nil, now: t0),
          "on a break or paused, Cmd-Tab follows")
    check(GateCore.followAllowed(mode: "Socials", unblocked: false, ready: "Socials", leftGated: nil, now: t0),
          "a wait that ran out lets Cmd-Tab in too")
    check(!GateCore.followAllowed(mode: "Socials", unblocked: false, ready: "Other", leftGated: nil, now: t0),
          "another mode ready does not")
}

// MARK: - The clock

func testReset() {
    let end = at(1200)
    func resets(deadline: Double, click: Double, now: Double, holds: Bool = false, running: Bool = true) -> Bool {
        GateCore.resets(deadline: at(deadline), roundEnd: end, focusRunning: running, clickedAt: at(click),
                        holds: holds, now: at(now))
    }
    check(!resets(deadline: 600, click: 0, now: 5), "5 s after a click the cut holds")
    check(resets(deadline: 600, click: 0, now: 5.1), "over 5 s without a click: back to the round's end")
    check(!resets(deadline: 1199.5, click: 0, now: 100), "a wait already at the round's end has nothing to reset")
    check(!resets(deadline: 30, click: 0, now: 10, holds: true), "an app held keeps the cut")
    check(!resets(deadline: 600, click: 0, now: 100, running: false), "a paused round resets nothing")
    check(!GateCore.resets(deadline: at(600), roundEnd: nil, focusRunning: true, clickedAt: t0, holds: false, now: at(100)),
          "no round end, nothing to go back to")
}

func testHold() {
    check(GateCore.holdsApp(launchFor: "Socials", pending: "Socials", deadline: at(59), clickedAt: t0),
          "an app asked for with under a minute left is held")
    check(!GateCore.holdsApp(launchFor: "Socials", pending: "Socials", deadline: at(60), clickedAt: t0),
          "a minute or more left: not held")
    check(!GateCore.holdsApp(launchFor: nil, pending: "Socials", deadline: at(10), clickedAt: t0),
          "no app asked for: not held")
    check(!GateCore.holdsApp(launchFor: "Other", pending: "Socials", deadline: at(10), clickedAt: t0),
          "an app of another mode: not held")
    check(GateCore.asking(clickedAt: t0, holds: false, now: at(5)), "a click in the last 5 s is still asking")
    check(!GateCore.asking(clickedAt: t0, holds: false, now: at(5.1)), "no click for over 5 s: not asking")
    check(GateCore.asking(clickedAt: t0, holds: true, now: at(50)), "an app held asks however long ago the click")
}

// MARK: - A whole burst

/// Clicks every `gap` seconds from a fresh start with a round of `left` seconds to go, as the dock
/// would apply them; returns when the wait ran out (the mode opens), or nil when it never did.
func burst(left: Double, gap: Double, clicks: Int) -> Double? {
    var nudges = 0, nudgedAt = Date.distantPast, pending: String?, deadline: Date?, clickedAt = Date.distantPast
    let end = at(left)
    var now = t0
    for _ in 0..<clicks {
        if let d = deadline, d <= now { return now.timeIntervalSince(t0) }
        if let d = deadline, GateCore.resets(deadline: d, roundEnd: end, focusRunning: true, clickedAt: clickedAt, holds: false, now: now) {
            deadline = end
        }
        let o = GateCore.tap(.init(name: "Socials", current: "Profile 1", gated: true, unblocked: false, focus: true,
                                   ready: nil, leftGated: nil, pending: pending, deadline: deadline, nudges: nudges,
                                   nudgedAt: nudgedAt, now: now))
        if now.timeIntervalSince(nudgedAt) > GateCore.clickPause { nudges = 0 }
        nudgedAt = now
        switch o {
        case .nudge(let n): nudges = n
        case .cut(let s): deadline = now.addingTimeInterval(s); clickedAt = now
        case .start: pending = "Socials"; deadline = end; clickedAt = now
        default: break
        }
        now = now.addingTimeInterval(gap)
    }
    if let d = deadline, GateCore.asking(clickedAt: clickedAt, holds: false, now: d) { return d.timeIntervalSince(t0) }
    return nil
}

func testBursts() {
    let steady = burst(left: 25 * 60, gap: 0.5, clicks: 200)
    check(steady != nil && steady! < 30, "steady clicking twice a second gets in within half a minute, took \(steady.map { "\($0) s" } ?? "never")")
    check(burst(left: 25 * 60, gap: 6, clicks: 200) == nil, "a click every 6 s never gets in: each resets the wait and warns")
    check(burst(left: 25 * 60, gap: 0.5, clicks: 3) == nil, "three clicks only warn")
    let late = burst(left: 20, gap: 1, clicks: 30)
    check(late != nil && late! <= 20, "with 20 s of the round left, clicking gets in by the round's end")
}

@main
struct GateTests {
    static func main() {
        testTap()
        testCut()
        testBack()
        testReset()
        testHold()
        testBursts()
        print("gate: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
