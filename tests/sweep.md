# Hand sweep

What `tests/run.sh` cannot reach: the dock driven with the real mouse and keyboard, the timer
running in real time, and the add-ins talking to their apps. Run this before a release, or after a
change to switching, the gate, the pomodoro or an add-in. Each line is a case and what must happen.
"Profile 1" is the mode you work in, "Socials" the gated one.

Last run: 8 November 2026, on 0.1.0, macOS 15. Every case passed.

## Setting up

- Back up `~/.config/workspace-bar/config.json` and `state.json` first.
- For the pomodoro, set `"pomodoro": {"focusMinutes": 0.5, "breakMinutes": 0.5}` and restart the
  dock: rounds and breaks then take 30 s. The long breaks (15 and 45 min) stay long; to end one,
  quit the dock, set `pomoEnd` in `state.json` a few seconds ahead (seconds since 2001-01-01) and
  start it again.
- Quit the dock before editing `state.json`: it writes the file when it quits.
- Follow `~/Library/Logs/workspace-bar.log`; most cases below show there as one or two lines.
- Afterwards put the config back and set the timer where it would have been.

## Socials' wait (focus round running)

- [x] A click on Socials warns (a halo on the timer), three times a burst; the fourth starts the wait.
- [x] Each further click cuts 15% of the wait left, never below 3 s.
- [x] 5 s without a click: the wait goes back to the round's end, and the warnings come back.
- [x] Steady clicking (about two a second) gets in within half a minute.
- [x] Leaving Socials and clicking it again within 5 s goes straight back; after that it warns.
- [x] An app of Socials opened from outside (Dock, Spotlight, `open -a`) is hidden again, and
      follows into Socials within 5 s of leaving it.
- [x] An app picked from Socials' card with under a minute of wait left shows its icon beside the
      countdown, and opens in front when the wait runs out, with no further clicks.
- [x] A card click that only warns holds no app for later.
- [x] Option-3 counts as a click on Socials.

## The pomodoro

Rounds and breaks:

- [x] Idle, a click on the timer starts a focus round; you stay where you are.
- [x] Idle, one click on Socials starts a round and its wait, with no warning first.
- [x] Focus ends with no wait running: the break begins, you stay where you are.
- [x] Focus ends with a wait running but no click for over 5 s: the break begins, the wait and its
      countdown clear, you stay where you are, and a click then opens Socials at once.
- [x] Focus ends with an app held from the card: Socials opens with that app in front.
- [x] On a break a click on Socials, or Option-3, opens it at once.
- [x] On a break an app of Socials opened from outside takes the dock into Socials.
- [x] A break ends in Socials: back to the mode you came from, and a click on Socials straight
      after warns (no 5 s way back).
- [x] A break ends elsewhere: you stay put.
- [x] The fourth break of a set is 15 minutes, the second set's is lunch (45).

Pause, Skip, Reset (the timer's right-click menu):

- [x] Pausing focus opens Socials: a click opens it, an app from outside follows, the browser
      extension stops blocking (`curl 127.0.0.1:47391/mode` says `"social": true`) and Raycast
      lists every app.
- [x] Pausing while still clicking for Socials opens it; pausing after the clicks stopped leaves
      you where you are.
- [x] Resuming focus from inside Socials goes back, with no 5 s way back.
- [x] Pausing and resuming a break inside Socials keeps you there.
- [x] A dock restart while paused keeps the pause, the time left and the mode.
- [x] Skip to Break with a wait running ends the wait and leaves you where you are.
- [x] Skip to Focus from inside Socials goes back.
- [x] Reset with a wait running clears it; Reset inside Socials (running or paused) goes back and
      stops the timer.

The day:

- [x] The Mac slept past the end of a block and the next one would be over too: the timer stops
      and leaves Socials ("block ended … ago, stopping").
- [x] A block ended a few seconds before the dock started: the next block begins.
- [x] The last block ends: "the day's plan is done", the timer stops and leaves Socials; the
      card says "Day complete", and the next click starts again at the first block.
- [x] Idle on a new day: the plan starts at the first block and today's count at 0.

## Add-ins (each switched off, checked, switched on again)

- [x] Cmd-Tab for this mode only: on, the dock's switcher with the mode's apps; off, macOS's own.
- [x] Option-1 to 3: on, they switch modes; off, they do nothing.
- [x] Raycast: on, Socials' apps are left out outside Socials and Raycast restarts with no window
      and a working hotkey; off, every app is listed again.
- [x] Rectangle: on, the bottom gap leaves room for the dock (main screen only) and Rectangle's
      own setting is recorded; off, Rectangle gets its own gap back and restarts.
- [x] Brave: on, x.com is blocked outside Socials; off, it loads within 2 s; on again, it is
      blocked within 4 s. (Chrome and Firefox use the same extension and were not run.)
- [x] Custom hooks: a script you own and only you can write runs on each switch, with `WB_FROM`,
      `WB_TO` and `WB_GATED`, its output in `~/Library/Logs/workspace-bar-hooks.log`; a
      group-writable one is refused with a line in the main log; off, nothing runs.

## Open questions

- With the timer stopped, the click on Socials that starts the round and the wait is not counted
  as a warning, so three warnings follow before the cuts begin. Count it as the first?
- Raycast hides Socials' apps about 10 s after you leave Socials; pausing just then restarts it
  twice within half a second (no window shows).
- Starting, pausing, resuming and resetting the timer are not logged; Skip and a block's end are.
